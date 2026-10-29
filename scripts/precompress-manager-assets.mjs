#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const scriptPath = fileURLToPath(import.meta.url);
const defaultRoot = path.resolve(path.dirname(scriptPath), "..");
const webPath = "manager/internal/manager/web";
const outputName = "precompressed";
const manifestName = `${outputName}/manifest.json`;
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const encodings = {
  gzip: {
    suffix: ".gz",
    encode: (bytes) => {
      const encoded = zlib.gzipSync(bytes, { level: 9 });
      // The gzip OS header otherwise differs between Windows and Unix builds.
      encoded[9] = 255;
      return encoded;
    },
    decode: zlib.gunzipSync,
  },
  br: {
    suffix: ".br",
    encode: (bytes) => zlib.brotliCompressSync(bytes, { params: {
      [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT,
      [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
      [zlib.constants.BROTLI_PARAM_SIZE_HINT]: bytes.length,
    } }),
    decode: zlib.brotliDecompressSync,
  },
};

function filesBelow(directory, prefix = "", publicOnly = false) {
  if (!fs.existsSync(directory)) return [];
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const relative = prefix + entry.name;
    if (publicOnly && (entry.name.startsWith(".") || entry.name.startsWith("_") ||
        relative === outputName || relative === "index.html" || relative.endsWith(".map"))) continue;
    assert.ok(!entry.isSymbolicLink(), `Static asset paths must not be symbolic links: ${relative}`);
    if (entry.isDirectory()) files.push(...filesBelow(path.join(directory, entry.name), `${relative}/`, publicOnly));
    else {
      assert.ok(entry.isFile(), `Static asset path is not a regular file: ${relative}`);
      files.push(relative);
    }
  }
  return files.sort();
}

function sources(root) {
  const directory = path.join(root, webPath);
  assert.ok(fs.statSync(directory).isDirectory(), `Manager web root is missing: ${directory}`);
  return { directory, files: filesBelow(directory, "", true) };
}

function outputFiles(directory) {
  const output = path.join(directory, outputName);
  if (!fs.existsSync(output)) return [];
  assert.ok(!fs.lstatSync(output).isSymbolicLink(), "Generated output directory must not be a symbolic link.");
  return filesBelow(output).map((file) => `${outputName}/${file}`);
}

function isTextAsset(file) { return /\.(?:js|css)$/i.test(file); }
function identity(bytes) { return { sha256: sha256(bytes), bytes: bytes.length }; }

export function generate(root = defaultRoot) {
  const { directory, files } = sources(root);
  // Inspect existing outputs before writing, so unexpected symlinks cannot
  // redirect a generated variant outside the public asset directory.
  const previous = outputFiles(directory);
  const outputs = new Map();
  const manifest = { schemaVersion: 1, assets: {} };
  for (const file of files) {
    const bytes = fs.readFileSync(path.join(directory, file));
    const record = identity(bytes);
    if (isTextAsset(file)) {
      for (const [encoding, tool] of Object.entries(encodings)) {
        const encoded = tool.encode(bytes);
        if (encoded.length >= bytes.length) continue;
        assert.ok(tool.decode(encoded).equals(bytes), `Compression changed decoded bytes: ${file} (${encoding})`);
        const output = `${outputName}/${file}${tool.suffix}`;
        outputs.set(output, encoded);
        record[encoding] = { file: output, bytes: encoded.length, sha256: sha256(encoded) };
      }
    }
    manifest.assets[file] = record;
  }
  outputs.set(manifestName, Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`));
  for (const [relative, bytes] of outputs) {
    const destination = path.join(directory, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, bytes);
  }
  for (const relative of previous) {
    if (!outputs.has(relative)) fs.unlinkSync(path.join(directory, relative));
  }
  return manifest;
}

export function check(root = defaultRoot) {
  const { directory, files } = sources(root);
  const existingOutputs = outputFiles(directory);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, manifestName), "utf8"));
  assert.deepEqual(Object.keys(manifest).sort(), ["assets", "schemaVersion"], "Unknown manifest fields.");
  assert.equal(manifest.schemaVersion, 1, "Unsupported static asset manifest schema.");
  assert.ok(manifest.assets && typeof manifest.assets === "object" && !Array.isArray(manifest.assets), "Manifest assets must be an object.");
  assert.deepEqual(Object.keys(manifest.assets).sort(), files, "Static asset inventory is stale; regenerate precompressed assets.");
  const expectedOutputs = [manifestName];
  for (const file of files) {
    const bytes = fs.readFileSync(path.join(directory, file));
    const record = manifest.assets[file];
    assert.equal(record.sha256, sha256(bytes), `Identity SHA-256 changed: ${file}`);
    assert.equal(record.bytes, bytes.length, `Identity size changed: ${file}`);
    const expectedKeys = ["sha256", "bytes"];
    for (const [encoding, tool] of Object.entries(encodings)) {
      const useful = isTextAsset(file) && tool.encode(bytes).length < bytes.length;
      if (!useful) {
        assert.equal(record[encoding], undefined, `Unnecessary encoding present: ${file} (${encoding})`);
        continue;
      }
      expectedKeys.push(encoding);
      const variant = record[encoding];
      assert.ok(variant && typeof variant === "object", `Missing encoding: ${file} (${encoding})`);
      assert.deepEqual(Object.keys(variant).sort(), ["bytes", "file", "sha256"], `Unknown encoding fields: ${file} (${encoding})`);
      const output = `${outputName}/${file}${tool.suffix}`;
      assert.equal(variant.file, output, `Invalid encoding path: ${file} (${encoding})`);
      const encoded = fs.readFileSync(path.join(directory, output));
      assert.equal(variant.bytes, encoded.length, `Encoding size changed: ${output}`);
      assert.equal(variant.sha256, sha256(encoded), `Encoding SHA-256 changed: ${output}`);
      assert.ok(encoded.length < bytes.length, `Encoding inflates the source: ${output}`);
      assert.ok(tool.decode(encoded).equals(bytes), `Decoded bytes differ: ${output}`);
      expectedOutputs.push(output);
    }
    assert.deepEqual(Object.keys(record).sort(), expectedKeys.sort(), `Unknown asset fields: ${file}`);
  }
  assert.deepEqual(existingOutputs.sort(), expectedOutputs.sort(), "Generated output inventory is stale; remove unlisted variants or regenerate.");
  return manifest;
}

export function selfTest() {
  const temporaryBase = path.resolve(os.tmpdir());
  const root = fs.mkdtempSync(path.join(temporaryBase, "tautweekly-static-assets-"));
  const directory = path.join(root, webPath);
  fs.mkdirSync(path.join(directory, "media"), { recursive: true });
  const write = (name, value) => fs.writeFileSync(path.join(directory, name), value);
  const snapshot = () => outputFiles(directory).map((file) => [file, sha256(fs.readFileSync(path.join(directory, file)))]);
  try {
    write("app.js", "// UTF-8: café\nconst message = 'repeatable public script';\n".repeat(100));
    write("app.css", "body{}"); // Every compressed form is larger than this source.
    write("index.html", "<html>dynamic document excluded from static caching</html>");
    write("app.js.map", "source map excluded");
    write("media/icon.png", Buffer.from([0, 255, 128, 42, 0]));
    const manifest = generate(root);
    assert.deepEqual(Object.keys(manifest.assets), ["app.css", "app.js", "media/icon.png"]);
    assert.equal(manifest.assets["app.css"].gzip, undefined);
    assert.equal(manifest.assets["app.css"].br, undefined);
    assert.equal(manifest.assets["media/icon.png"].gzip, undefined);
    check(root);
    const gzipHeader = fs.readFileSync(path.join(directory, manifest.assets["app.js"].gzip.file));
    assert.equal(gzipHeader[9], 255, "Gzip metadata must not depend on the host operating system.");
    assert.equal(gzipHeader.readUInt32LE(4), 0, "Gzip metadata must not include a generation timestamp.");
    const before = snapshot();
    generate(root);
    assert.deepEqual(snapshot(), before, "Repeated generation must be byte-identical.");
    for (const [encoding, tool] of Object.entries(encodings)) {
      const variant = manifest.assets["app.js"][encoding];
      assert.ok(tool.decode(fs.readFileSync(path.join(directory, variant.file))).equals(fs.readFileSync(path.join(directory, "app.js"))));
    }
    const gzipPath = path.join(directory, manifest.assets["app.js"].gzip.file);
    fs.unlinkSync(gzipPath);
    assert.throws(() => check(root), /ENOENT/, "Missing variants must fail.");
    generate(root);
    write("precompressed/unlisted.gz", Buffer.from("unlisted output"));
    assert.throws(() => check(root), /output inventory is stale/, "Unlisted variants must fail.");
    generate(root);
    write("app.js", "changed source");
    assert.throws(() => check(root), /Identity SHA-256 changed/, "Stale identity must fail.");
    generate(root);
    write("app.js", "const current = 'repeated';\n".repeat(100));
    generate(root);
    const invalid = zlib.gzipSync(Buffer.from("wrong decoded content"));
    const editedManifest = JSON.parse(fs.readFileSync(path.join(directory, manifestName), "utf8"));
    editedManifest.assets["app.js"].gzip.bytes = invalid.length;
    editedManifest.assets["app.js"].gzip.sha256 = sha256(invalid);
    fs.writeFileSync(gzipPath, invalid);
    write(manifestName, JSON.stringify(editedManifest));
    assert.throws(() => check(root), /Decoded bytes differ/, "Valid hashes must not conceal a non-equivalent encoding.");
    generate(root);
    fs.unlinkSync(path.join(directory, "media/icon.png"));
    assert.throws(() => check(root), /inventory is stale/, "Removed sources must fail.");
    generate(root);
    check(root);
    console.log("[PASS] Static compression is deterministic, lossless and smaller-only; stale, missing, unlisted and non-equivalent outputs fail.");
  } finally {
    assert.ok(root.startsWith(`${temporaryBase}${path.sep}`) && path.basename(root).startsWith("tautweekly-static-assets-"));
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function main() {
  const args = process.argv.slice(2);
  let root = defaultRoot;
  for (let index = 0; index < args.length; index++) {
    if (args[index] === "--root") {
      assert.ok(args[index + 1], "--root requires a repository directory.");
      root = path.resolve(args[++index]);
    } else assert.ok(["--check", "--self-test"].includes(args[index]), `Unknown option: ${args[index]}`);
  }
  if (args.includes("--self-test")) selfTest();
  else {
    const manifest = args.includes("--check") ? check(root) : generate(root);
    console.log(`[PASS] ${args.includes("--check") ? "Verified" : "Generated"} fingerprints and lossless static encodings for ${Object.keys(manifest.assets).length} public Manager assets.`);
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) main();
