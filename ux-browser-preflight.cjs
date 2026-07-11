#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key.startsWith('--') || value === undefined) {
      throw new Error(`Invalid argument near ${key}`);
    }
    args[key.slice(2)] = value;
  }
  return args;
}

function readCredentialUrl(repoRoot) {
  const credentialsPath = path.join(repoRoot, 'docs', 'ux', '.creds');
  if (!fs.existsSync(credentialsPath)) return '';
  const lines = fs.readFileSync(credentialsPath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const match = line.match(/^\s*(?:url|base_url|frontend_url)\s*[=:]\s*(.+?)\s*$/i);
    if (match) return match[1].replace(/^['"]|['"]$/g, '');
  }
  return '';
}

function resolvePlaywright(repoRoot) {
  const searchPaths = [path.join(repoRoot, 'frontend'), repoRoot];
  try {
    return require(require.resolve('playwright', { paths: searchPaths }));
  } catch {
    return null;
  }
}

function installChromium(repoRoot, summaryLog) {
  const frontendRoot = path.join(repoRoot, 'frontend');
  const packageRoot = fs.existsSync(path.join(frontendRoot, 'package.json')) ? frontendRoot : repoRoot;
  summaryLog.push(`Installing the Playwright-version-matched Chromium from ${packageRoot}.`);
  const result = spawnSync('npx', ['playwright', 'install', 'chromium'], {
    cwd: packageRoot,
    encoding: 'utf8',
    timeout: 600000,
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || 'install failed').trim().split(/\r?\n/).slice(-8).join('\n');
    throw new Error(`Playwright Chromium installation failed:\n${detail}`);
  }
}

function writeSummary(outDir, status, details) {
  fs.mkdirSync(outDir, { recursive: true });
  const markdown = ['# UX Browser Preflight', '', `STATUS: ${status}`, '', ...details, ''].join('\n');
  fs.writeFileSync(path.join(outDir, 'summary.md'), markdown);
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify({ status, details }, null, 2) + '\n');
}

async function main() {
  const args = parseArgs(process.argv);
  const repoRoot = path.resolve(args['repo-root']);
  const outDir = path.join(path.resolve(args['run-dir']), 'artifacts', 'browser-preflight');
  fs.mkdirSync(outDir, { recursive: true });
  const details = [];
  const baseUrl = process.env.UX_BROWSER_BASE_URL || process.env.AUDIT_BROWSER_BASE_URL ||
    process.env.E2E_BASE_URL || readCredentialUrl(repoRoot);
  if (!baseUrl) throw new Error('No deployed browser URL found in environment or docs/ux/.creds.');

  let playwright = resolvePlaywright(repoRoot);
  if (!playwright) throw new Error('The product does not have Playwright installed.');
  let executablePath = playwright.chromium.executablePath();
  if (!fs.existsSync(executablePath)) {
    if (args['auto-install'] !== '1') throw new Error(`Chromium is missing at ${executablePath}.`);
    installChromium(repoRoot, details);
    playwright = resolvePlaywright(repoRoot);
    executablePath = playwright.chromium.executablePath();
  }
  if (!fs.existsSync(executablePath)) throw new Error(`Chromium remains missing at ${executablePath}.`);

  const browser = await playwright.chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const response = await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.screenshot({ path: path.join(outDir, 'entry-page.png'), fullPage: true });
    const status = response ? response.status() : 0;
    if (status >= 500 || status === 0) throw new Error(`Deployed entry point returned HTTP ${status || 'unknown'}.`);
    details.push(`Deployed entry point reached successfully with HTTP ${status}.`);
    details.push(`Browser engine: ${playwright.chromium.name()} at ${executablePath}.`);
    details.push('A first-page screenshot was captured without persisting credentials.');
    writeSummary(outDir, 'PASS', details);
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  const args = (() => { try { return parseArgs(process.argv); } catch { return {}; } })();
  const runDir = args['run-dir'] ? path.resolve(args['run-dir']) : process.cwd();
  const outDir = path.join(runDir, 'artifacts', 'browser-preflight');
  writeSummary(outDir, 'FAIL', [String(error && error.message ? error.message : error)]);
  process.exitCode = 1;
});
