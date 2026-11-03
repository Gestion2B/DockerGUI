'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const port = Number(process.env.PORT || 8780);
const root = process.env.DATA_ROOT || '/data';
const uiRoot = path.join(__dirname, 'actualizador-ui');
const jobsRoot = path.join(root, 'gui-jobs');
const configFile = path.join(root, 'proyectos-produccion.txt');
const token = crypto.randomBytes(24).toString('hex');
const actions = new Set(['Promote', 'Rollback', 'RestoreAll', 'BackupDatabase', 'BackupAllDatabases', 'VerifyBackup', 'VerifyAllBackups', 'ExternalBackup', 'ExternalVerify']);
const actionByPath = {
  '/api/promote': 'Promote', '/api/rollback': 'Rollback', '/api/restore-all': 'RestoreAll',
  '/api/backup': 'BackupDatabase', '/api/backup-all': 'BackupAllDatabases',
  '/api/verify': 'VerifyBackup', '/api/verify-all': 'VerifyAllBackups',
  '/api/external-backup': 'ExternalBackup', '/api/external-verify': 'ExternalVerify'
};
const confirmationByAction = {
  Promote: 'ACTUALIZAR', Rollback: 'RESTAURAR', RestoreAll: 'RESTAURAR TODO',
  BackupDatabase: 'COPIAR', BackupAllDatabases: 'COPIAR', VerifyBackup: 'VERIFICAR', VerifyAllBackups: 'VERIFICAR',
  ExternalBackup: 'COPIAR', ExternalVerify: 'VERIFICAR'
};
// De momento la copia a disco externo solo esta preparada para estos proyectos.
const externalProjects = new Set(['app-fotos']);
function isWindowsPath(value) {
  return typeof value === 'string' && value.length <= 4096 && !/[\r\n"<>|?*]/.test(value.replace(/^[a-zA-Z]:/, '')) && /^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+)/.test(value.trim());
}

function ensureDirectories() { fs.mkdirSync(jobsRoot, { recursive: true }); }
function file(name) { return path.join(jobsRoot, name); }
function safeRead(name, fallback = null) {
  try { return fs.readFileSync(name, 'utf8'); } catch { return fallback; }
}
function safeJson(name, fallback = null) {
  try {
    // PowerShell puede guardar ConvertTo-Json con UTF-8 BOM. JSON.parse no lo acepta.
    const content = fs.readFileSync(name, 'utf8').replace(/^\uFEFF/, '');
    return JSON.parse(content);
  } catch { return fallback; }
}
function writeJsonAtomic(name, value) {
  const temp = `${name}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value), 'utf8');
  fs.renameSync(temp, name);
}
function updateTestingPath(projectId, testingPath) {
  if (!/^[a-z0-9][a-z0-9_.-]*$/.test(projectId || '')) throw new Error('Proyecto no valido.');
  if (typeof testingPath !== 'string' || testingPath.length > 4096 || /[\r\n]/.test(testingPath)) throw new Error('Ruta de pruebas no valida.');
  const normalized = testingPath.trim();
  if (normalized && !/^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+)/.test(normalized)) {
    throw new Error('Usa una ruta absoluta de Windows, por ejemplo C:\\Proyectos\\MiApp\\pruebas.');
  }
  const source = safeRead(configFile);
  if (source === null) throw new Error('No se encontro proyectos-produccion.txt.');
  const lines = source.replace(/^\uFEFF/, '').split(/\r?\n/);
  const sectionStart = lines.findIndex(line => line.trim().toLowerCase() === `[${projectId.toLowerCase()}]`);
  if (sectionStart < 0) throw new Error('No se encontro este proyecto en el TXT.');
  let sectionEnd = lines.length;
  for (let index = sectionStart + 1; index < lines.length; index++) {
    if (/^\s*\[[^\]]+\]\s*$/.test(lines[index])) { sectionEnd = index; break; }
  }
  const keyIndex = lines.findIndex((line, index) => index > sectionStart && index < sectionEnd && /^\s*pruebas\s*=/i.test(line));
  if (normalized) {
    const replacement = `Pruebas=${normalized}`;
    if (keyIndex >= 0) lines[keyIndex] = replacement;
    else lines.splice(sectionEnd, 0, replacement);
  } else if (keyIndex >= 0) {
    lines.splice(keyIndex, 1);
  }
  const temp = `${configFile}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temp, lines.join('\r\n'), 'utf8');
  fs.renameSync(temp, configFile);
  return { project: projectId, testingPath: normalized || null };
}
function tail(name, count = 120) {
  const content = safeRead(name, '');
  return content ? content.split(/\r?\n/).filter(Boolean).slice(-count) : [];
}
function isId(value) { return typeof value === 'string' && /^[a-f0-9]{32}$/.test(value); }
function currentJobs() {
  ensureDirectories();
  return fs.readdirSync(jobsRoot).filter(n => n.endsWith('.job.json')).map(n => n.slice(0, -9));
}
function jobState(id) {
  if (!isId(id)) throw new Error('Identificador de operacion no valido.');
  const job = safeJson(file(`${id}.job.json`));
  if (!job) throw new Error('No se encontro esta operacion.');
  const result = safeJson(file(`${id}.result.json`));
  const progress = safeJson(file(`${id}.progress.json`));
  const finalLog = tail(file(`${id}.output.log`));
  const liveLog = tail(file(`${id}.stdout.log`));
  const recentLog = finalLog.length > 1 || !liveLog.length ? finalLog : [...finalLog, ...liveLog].slice(-120);
  const started = new Date(job.startedAt || Date.now());
  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - started.getTime()) / 1000));
  const queued = fs.existsSync(file(`${id}.queue.json`)) || fs.existsSync(file(`${id}.processing.json`));
  let state = 'running', success = false;
  if (result) { state = 'completed'; success = result.success === true; }
  else if (!queued) { state = 'unknown'; }
  let output = recentLog.join('\n');
  if (result && result.error) output += `${output ? '\n' : ''}${result.error}`;
  if (!output) output = result ? (success ? 'Operacion completada.' : 'La operacion termino con errores.') : 'Operación en curso.';
  return { success, state, jobId: id, action: job.action, elapsedSeconds, recentLog, output, progress };
}
function activeJob() {
  const candidates = currentJobs().sort((a, b) => {
    const aa = safeJson(file(`${a}.job.json`), {}), bb = safeJson(file(`${b}.job.json`), {});
    return new Date(bb.startedAt || 0) - new Date(aa.startedAt || 0);
  });
  for (const id of candidates) {
    const result = safeJson(file(`${id}.result.json`));
    if (result) continue;
    if (fs.existsSync(file(`${id}.queue.json`)) || fs.existsSync(file(`${id}.processing.json`))) return jobState(id);
  }
  return null;
}
function diagnosticLog() {
  const lines = [];
  const addSection = (title, source) => {
    const entries = tail(source, 80);
    if (!entries.length) return;
    lines.push(`--- ${title} ---`, ...entries, '');
  };
  addSection('Trabajador local de PowerShell', path.join(root, 'Gui-Docker', 'worker.log'));
  addSection('Registro general', path.join(root, 'actualizaciones.log'));

  const jobs = currentJobs().map(id => safeJson(file(`${id}.job.json`), { id }))
    .sort((a, b) => new Date(b.startedAt || 0) - new Date(a.startedAt || 0)).slice(0, 5);
  for (const job of jobs) {
    const result = safeJson(file(`${job.id}.result.json`));
    const state = result ? (result.success ? 'COMPLETADO' : 'ERROR') :
      (fs.existsSync(file(`${job.id}.processing.json`)) ? 'EJECUTANDO' : fs.existsSync(file(`${job.id}.queue.json`)) ? 'EN COLA' : 'SIN ESTADO');
    lines.push(`--- Trabajo ${job.id} · ${job.action || 'desconocido'} · ${state} ---`);
    const output = tail(file(`${job.id}.output.log`), 120);
    if (output.length) lines.push(...output);
    else if (result?.error) lines.push(result.error);
    else lines.push('Todavía no hay salida disponible.');
    lines.push('');
  }
  return lines.length ? lines : ['No hay trabajos ni mensajes registrados todavía.'];
}
function dashboard() {
  // En Windows el trabajador escribe dentro de Gui-Docker. Dentro del
  // contenedor Linux las mayusculas importan, por eso se usa el nombre real.
  const state = safeJson(path.join(root, 'Gui-Docker', 'dashboard.json'));
  if (state) return state;
  return { generatedAt: new Date().toISOString(), dockerReady: false, projects: [], message: 'Esperando al trabajador local de PowerShell.' };
}
function json(res, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}
function html(res, source) {
  const body = Buffer.from(source.replace('__LOCAL_TOKEN__', token));
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': body.length, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.setEncoding('utf8');
    req.on('data', part => { data += part; if (data.length > 65536) reject(new Error('Peticion demasiado grande.')); });
    req.on('end', () => resolve(data ? JSON.parse(data) : {}));
    req.on('error', reject);
  });
}
function startJob(action, payload) {
  if (!actions.has(action)) throw new Error('Accion no valida.');
  if (activeJob()) throw new Error('Ya hay una operacion en curso.');
  if ((payload.confirm || '') !== confirmationByAction[action]) throw new Error('Confirmacion incorrecta.');
  const projectActions = new Set(['Promote', 'Rollback', 'BackupDatabase', 'VerifyBackup', 'ExternalBackup', 'ExternalVerify']);
  const backupActions = new Set(['Rollback', 'VerifyBackup']);
  if (projectActions.has(action) && !/^[a-z0-9][a-z0-9_.-]*$/.test(payload.project || '')) throw new Error('Proyecto no valido.');
  if (backupActions.has(action) && (!payload.backup || /[\\/]/.test(payload.backup))) throw new Error('Copia no valida.');
  const isExternal = action === 'ExternalBackup' || action === 'ExternalVerify';
  if (isExternal && !externalProjects.has(payload.project)) throw new Error('De momento la copia a disco externo solo esta preparada para: ' + [...externalProjects].join(', ') + '.');
  if (isExternal && !isWindowsPath(payload.destination)) throw new Error('Indica la carpeta del disco externo como ruta absoluta de Windows, por ejemplo D:\\BackupsMonzon.');
  const id = crypto.randomBytes(16).toString('hex');
  const job = { id, action, project: payload.project || null, backup: payload.backup || null, destination: isExternal ? payload.destination.trim() : null, startedAt: new Date().toISOString(), source: 'docker-api' };
  writeJsonAtomic(file(`${id}.job.json`), job);
  writeJsonAtomic(file(`${id}.queue.json`), job);
  return { success: true, jobId: id, state: 'running' };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);
  try {
    if (req.method === 'GET' && url.pathname === '/') return html(res, fs.readFileSync(path.join(uiRoot, 'index.html'), 'utf8'));
    if (req.method === 'GET' && url.pathname === '/api/status') return json(res, 200, dashboard());
    if (req.method === 'GET' && url.pathname === '/api/active-job') return json(res, 200, { job: activeJob() });
    if (req.method === 'GET' && url.pathname === '/api/job') return json(res, 200, jobState(url.searchParams.get('job') || ''));
    if (req.method === 'GET' && url.pathname === '/api/log') return json(res, 200, { lines: diagnosticLog() });
    if (req.method === 'POST' && url.pathname === '/api/testing-path') {
      if (req.headers['x-local-token'] !== token) return json(res, 403, { error: 'Token local no valido.' });
      const body = await readBody(req);
      return json(res, 200, { success: true, ...updateTestingPath(body.project, body.testingPath) });
    }
    if (req.method === 'POST' && Object.prototype.hasOwnProperty.call(actionByPath, url.pathname)) {
      if (req.headers['x-local-token'] !== token) return json(res, 403, { error: 'Token local no valido.' });
      return json(res, 200, startJob(actionByPath[url.pathname], await readBody(req)));
    }
    if (req.method === 'POST' && url.pathname === '/api/shutdown') return json(res, 200, { success: true });
    return json(res, 404, { error: 'Ruta no encontrada.' });
  } catch (error) { return json(res, 400, { error: error.message || 'Error interno.' }); }
});

ensureDirectories();
// Dentro de un contenedor 127.0.0.1 solo es el propio contenedor. El puerto
// publicado por Compose ya se limita a 127.0.0.1 en Windows.
server.listen(port, '0.0.0.0', () => console.log(`Docker Updater API: http://127.0.0.1:${port}`));
