const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Use node:sqlite built-in module
const { DatabaseSync } = require('node:sqlite');

const ROOT = 'C:\\MachinetranslateAI';
const DB_DIR = path.join(process.env.USERPROFILE || process.env.HOME, '.context-mode', 'content');

// Ensure directory exists
if (!fs.existsSync(DB_DIR)) {
  fs.mkdirSync(DB_DIR, { recursive: true });
}

// Create project-specific DB
const projectId = crypto.createHash('md5').update(ROOT).digest('hex').substring(0, 8);
const dbPath = path.join(DB_DIR, `${projectId}.db`);

console.log(`Database: ${dbPath}`);

const db = new DatabaseSync(dbPath);

// Apply WAL pragmas
db.exec('PRAGMA journal_mode = WAL');
db.exec('PRAGMA synchronous = NORMAL');

// Create tables
db.exec(`
  CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    label TEXT NOT NULL,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    code_chunk_count INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
    file_path TEXT,
    content_hash TEXT
  );

  CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
    title,
    content,
    source_id UNINDEXED,
    content_type UNINDEXED,
    tokenize='porter unicode61'
  );

  CREATE VIRTUAL TABLE IF NOT EXISTS chunks_trigram USING fts5(
    title,
    content,
    source_id UNINDEXED,
    content_type UNINDEXED,
    tokenize='trigram'
  );

  CREATE TABLE IF NOT EXISTS vocabulary (
    word TEXT PRIMARY KEY
  );

  CREATE INDEX IF NOT EXISTS idx_sources_label ON sources(label);
`);

// Read project index
const indexContent = fs.readFileSync(path.join(ROOT, 'project-index.md'), 'utf8');

// Chunk by headings
function chunkMarkdown(text) {
  const chunks = [];
  const lines = text.split('\n');
  let currentTitle = '';
  let currentContent = [];

  for (const line of lines) {
    if (line.startsWith('#')) {
      if (currentContent.length > 0 && currentTitle) {
        chunks.push({
          title: currentTitle,
          content: currentContent.join('\n').trim()
        });
      }
      currentTitle = line.replace(/^#+\s*/, '');
      currentContent = [];
    } else {
      currentContent.push(line);
    }
  }

  if (currentContent.length > 0 && currentTitle) {
    chunks.push({
      title: currentTitle,
      content: currentContent.join('\n').trim()
    });
  }

  return chunks;
}

const chunks = chunkMarkdown(indexContent);
console.log(`Chunks to index: ${chunks.length}`);

// Insert into database
const insertSource = db.prepare(
  "INSERT INTO sources (label, chunk_count, code_chunk_count, file_path, content_hash) VALUES (?, ?, ?, ?, ?)"
);

const insertChunk = db.prepare(
  "INSERT INTO chunks (title, content, source_id, content_type) VALUES (?, ?, ?, ?)"
);

const insertChunkTrigram = db.prepare(
  "INSERT INTO chunks_trigram (title, content, source_id, content_type) VALUES (?, ?, ?, ?)"
);

const insertVocab = db.prepare(
  "INSERT OR IGNORE INTO vocabulary (word) VALUES (?)"
);

// Delete existing if any
db.prepare("DELETE FROM chunks WHERE source_id IN (SELECT id FROM sources WHERE label = ?)").run('project-index.md');
db.prepare("DELETE FROM chunks_trigram WHERE source_id IN (SELECT id FROM sources WHERE label = ?)").run('project-index.md');
db.prepare("DELETE FROM sources WHERE label = ?").run('project-index.md');

const sourceInfo = insertSource.run('project-index.md', chunks.length, 0, 'project-index.md', null);
const sourceId = Number(sourceInfo.lastInsertRowid);

for (const chunk of chunks) {
  if (chunk.content.length > 0) {
    insertChunk.run(chunk.title, chunk.content, sourceId, 'prose');
    insertChunkTrigram.run(chunk.title, chunk.content, sourceId, 'prose');
  }
}

// Extract vocabulary
const words = indexContent
  .toLowerCase()
  .split(/[^\p{L}\p{N}_-]+/u)
  .filter(w => w.length >= 3);

const unique = [...new Set(words)];
for (const word of unique) {
  insertVocab.run(word);
}

console.log(`Indexed ${chunks.length} chunks from project-index.md`);
console.log(`Vocabulary: ${unique.length} words`);

// Now index the Dart files
const SKIP = ['node_modules', '.git', 'context-mode', '.opencode', 'dist', 'build', '__pycache__', '.dart_tool', 'android', 'ios', 'linux', 'macos', 'windows', 'web'];

function walk(dir, depth = 0) {
  if (depth > 5) return [];
  const results = [];
  try {
    const items = fs.readdirSync(dir);
    for (const item of items) {
      if (SKIP.includes(item)) continue;
      const full = path.join(dir, item);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        results.push(...walk(full, depth + 1));
      } else if (item.endsWith('.dart')) {
        results.push(full);
      }
    }
  } catch (e) {}
  return results;
}

const dartFiles = walk(ROOT);
console.log(`\nIndexing ${dartFiles.length} Dart files...`);

for (const filePath of dartFiles) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const relativePath = path.relative(ROOT, filePath);
    
    // Simple chunk by class/function
    const fileChunks = [];
    const lines = content.split('\n');
    let currentTitle = relativePath;
    let currentContent = [];
    
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.match(/^class\s+(\w+)/) || trimmed.match(/^(void|int|String|bool|double|List|Map|Future|Stream|Widget)\s+(\w+)\s*\(/)) {
        if (currentContent.length > 0) {
          fileChunks.push({
            title: currentTitle,
            content: currentContent.join('\n').trim()
          });
        }
        currentTitle = `${relativePath}::${trimmed.split('(')[0].split(' ')[1] || trimmed}`;
        currentContent = [];
      } else {
        currentContent.push(line);
      }
    }
    
    if (currentContent.length > 0) {
      fileChunks.push({
        title: currentTitle,
        content: currentContent.join('\n').trim()
      });
    }
    
    // Delete existing
    db.prepare("DELETE FROM chunks WHERE source_id IN (SELECT id FROM sources WHERE label = ?)").run(relativePath);
    db.prepare("DELETE FROM chunks_trigram WHERE source_id IN (SELECT id FROM sources WHERE label = ?)").run(relativePath);
    db.prepare("DELETE FROM sources WHERE label = ?").run(relativePath);
    
    const info = insertSource.run(relativePath, fileChunks.length, fileChunks.length, filePath, null);
    const srcId = Number(info.lastInsertRowid);
    
    for (const chunk of fileChunks) {
      if (chunk.content.length > 0) {
        insertChunk.run(chunk.title, chunk.content, srcId, 'code');
        insertChunkTrigram.run(chunk.title, chunk.content, srcId, 'code');
      }
    }
    
    // Extract vocab
    const fileWords = content
      .toLowerCase()
      .split(/[^\p{L}\p{N}_-]+/u)
      .filter(w => w.length >= 3);
    
    for (const word of [...new Set(fileWords)]) {
      insertVocab.run(word);
    }
    
  } catch (e) {
    console.error(`Error indexing ${filePath}: ${e.message}`);
  }
}

// Get stats
const stats = db.prepare(`
  SELECT 
    (SELECT COUNT(*) FROM sources) AS sources,
    (SELECT COUNT(*) FROM chunks) AS chunks,
    (SELECT COUNT(*) FROM chunks WHERE content_type = 'code') AS codeChunks
`).get();

console.log('\n=== INDEX COMPLETE ===');
console.log(`Sources: ${stats.sources}`);
console.log(`Chunks: ${stats.chunks}`);
console.log(`Code chunks: ${stats.codeChunks}`);
console.log(`Database: ${dbPath}`);

db.close();
