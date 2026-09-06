// Generuje ksef-bookmarklet-url.txt z ksef-auto-pobieranie-bookmarklet.js.
// Uruchom po każdej zmianie w pliku źródłowym: node generate-bookmarklet.js
const fs = require('fs');
const path = require('path');

const srcPath = path.join(__dirname, 'ksef-auto-pobieranie-bookmarklet.js');
const outPath = path.join(__dirname, 'ksef-bookmarklet-url.txt');

const src = fs.readFileSync(srcPath, 'utf8');

// Sanity check: kod musi się dać sparsować jako poprawny JS zanim go zakodujemy.
new Function(src);

const encoded = 'javascript:' + encodeURIComponent(src);
fs.writeFileSync(outPath, encoded);

console.log(`OK: wygenerowano ${outPath} (${encoded.length} znaków).`);
console.log('Wklej całą zawartość tego pliku jako URL zakładki w przeglądarce.');
