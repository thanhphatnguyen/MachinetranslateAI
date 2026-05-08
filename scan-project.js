const fs = require('fs');
const path = require('path');

const ROOT = 'C:\\MachinetranslateAI';
const SKIP = ['node_modules', '.git', 'context-mode', '.opencode', 'dist', 'build', '__pycache__'];

function walk(dir, depth = 0) {
  if (depth > 4) return [];
  const results = [];
  try {
    const items = fs.readdirSync(dir);
    for (const item of items) {
      if (SKIP.includes(item)) continue;
      const full = path.join(dir, item);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        results.push({ type: 'dir', path: path.relative(ROOT, full), depth });
        results.push(...walk(full, depth + 1));
      } else {
        results.push({ type: 'file', path: path.relative(ROOT, full), size: stat.size, depth });
      }
    }
  } catch (e) {}
  return results;
}

function analyzeFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const funcs = [];
    const classes = [];
    const imports = [];
    
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.match(/^(export\s+)?(async\s+)?function\s+(\w+)/)) {
        funcs.push(RegExp.$3);
      }
      if (trimmed.match(/^(export\s+)?class\s+(\w+)/)) {
        classes.push(RegExp.$2);
      }
      if (trimmed.match(/^import\s+.*from\s+['"](.+)['"]/)) {
        imports.push(RegExp.$1);
      }
      if (trimmed.match(/^(const|let|var)\s+(\w+)\s*=\s*(async\s+)?\(/)) {
        funcs.push(RegExp.$2);
      }
    }
    
    return { lines: lines.length, funcs, classes, imports };
  } catch (e) {
    return null;
  }
}

console.log('=== PROJECT STRUCTURE ===');
const tree = walk(ROOT);
const dirs = tree.filter(i => i.type === 'dir').length;
const files = tree.filter(i => i.type === 'file');
console.log(`Directories: ${dirs}, Files: ${files.length}`);

console.log('\n=== CODE ANALYSIS ===');
const codeFiles = files.filter(f => f.path.match(/\.(js|ts|py|jsx|tsx)$/));
let totalLines = 0;
let allFuncs = [];
let allClasses = [];

for (const file of codeFiles) {
  const analysis = analyzeFile(path.join(ROOT, file.path));
  if (analysis) {
    totalLines += analysis.lines;
    allFuncs.push(...analysis.funcs.map(f => `${file.path}:${f}`));
    allClasses.push(...analysis.classes.map(c => `${file.path}:${c}`));
  }
}

console.log(`Code files: ${codeFiles.length}`);
console.log(`Total lines: ${totalLines}`);
console.log(`Functions: ${allFuncs.length}`);
console.log(`Classes: ${allClasses.length}`);

console.log('\n=== TOP FILES BY SIZE ===');
files.sort((a, b) => b.size - a.size);
files.slice(0, 10).forEach(f => {
  console.log(`${(f.size/1024).toFixed(1)}KB - ${f.path}`);
});

console.log('\n=== FUNCTIONS FOUND ===');
allFuncs.forEach(f => console.log(f));

console.log('\n=== CLASSES FOUND ===');
allClasses.forEach(c => console.log(c));
