const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const WDA_PORT = process.env.WDA_PORT || 8100;
const BASE_URL = `http://127.0.0.1:${WDA_PORT}`;
const BUNDLE_ID = 'dev.autopilot.test.Explorea';
const EVIDENCE_DIR = process.env.EVIDENCE_DIR || 'evidence';
const EVIDENCE_PREFIX = process.env.EVIDENCE_PREFIX || 'wda';

async function request(method, urlPath, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(`${BASE_URL}${urlPath}`, opts);
  const text = await res.text();
  try { return JSON.parse(text); }
  catch { return text; }
}

async function createSession() {
  const res = await request('POST', '/session', {
    capabilities: { alwaysMatch: { bundleId: BUNDLE_ID } },
  });
  if (!res.value || !res.value.sessionId) {
    throw new Error('Failed to create session: ' + JSON.stringify(res));
  }
  return res.value.sessionId;
}

async function deleteSession(sessionId) {
  await request('DELETE', `/session/${sessionId}`);
}

async function findElement(sessionId, text) {
  const res = await request('POST', `/session/${sessionId}/element`, {
    using: 'predicate string',
    value: `label == "${text}" OR name == "${text}"`,
  });
  if (!res.value || !res.value.ELEMENT) {
    const el = res.value && Object.values(res.value)[0];
    if (!el) throw new Error(`Element not found: ${text}`);
    return el;
  }
  return res.value.ELEMENT;
}

async function tapElement(sessionId, elementId) {
  await request('POST', `/session/${sessionId}/element/${elementId}/click`);
}

async function findAndTap(sessionId, text) {
  const elementId = await findElement(sessionId, text);
  await tapElement(sessionId, elementId);
}

async function waitForElement(sessionId, text, timeoutMs = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      return await findElement(sessionId, text);
    } catch {
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error(`Timeout waiting for: ${text}`);
}

async function saveScreenshot(sessionId, filename) {
  const res = await request('GET', `/session/${sessionId}/screenshot`);
  if (res.value) {
    const buffer = Buffer.from(res.value, 'base64');
    const filePath = path.resolve(filename);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, buffer);
  }
}

// Biometric via Simulator menu (AppleScript) — same approach as AutoPilot CLI.
// WDA and simctl have no biometric endpoints on Xcode 26.
function biometricIsEnrolled() {
  const script = `
    tell application "System Events" to tell process "Simulator"
      set enrolledItem to menu item "Enrolled" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
      set m to value of attribute "AXMenuItemMarkChar" of enrolledItem
      if m is missing value then return "false"
      return "true"
    end tell`;
  const out = execSync(`osascript -e '${script.replace(/'/g, "'\\''")}'`, { encoding: 'utf8' }).trim();
  return out === 'true';
}

function clickSimulatorMenu(menuItem) {
  const script = `tell application "System Events" to tell process "Simulator" to click menu item "${menuItem}" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1`;
  // Activate Simulator first so menu is accessible
  execSync('osascript -e \'tell application "Simulator" to activate\'', { stdio: 'ignore' });
  execSync(`osascript -e '${script}'`, { stdio: 'ignore' });
}

function enrollBiometric(enabled = true) {
  const enrolled = biometricIsEnrolled();
  if (enabled && !enrolled) {
    clickSimulatorMenu('Enrolled');
  } else if (!enabled && enrolled) {
    clickSimulatorMenu('Enrolled');
  }
}

function sendBiometricMatch(match = true) {
  const item = match ? 'Matching Face' : 'Non-matching Face';
  clickSimulatorMenu(item);
}

async function terminateApp(sessionId) {
  await request('POST', `/session/${sessionId}/wda/apps/terminate`, {
    bundleId: BUNDLE_ID,
  });
}

async function activateApp(sessionId) {
  await request('POST', `/session/${sessionId}/wda/apps/launch`, {
    bundleId: BUNDLE_ID,
  });
}

async function swipeUp(sessionId) {
  // WDA swipe via touch actions
  const winSize = await request('GET', `/session/${sessionId}/window/size`);
  const w = winSize.value.width;
  const h = winSize.value.height;
  await request('POST', `/session/${sessionId}/wda/touch/perform`, {
    actions: [
      { action: 'press', options: { x: w / 2, y: h * 0.7 } },
      { action: 'wait', options: { ms: 200 } },
      { action: 'moveTo', options: { x: w / 2, y: h * 0.3 } },
      { action: 'release' },
    ],
  });
}

async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

module.exports = {
  createSession, deleteSession,
  findAndTap, waitForElement, saveScreenshot,
  enrollBiometric, sendBiometricMatch,
  terminateApp, activateApp, swipeUp, sleep,
  EVIDENCE_DIR, EVIDENCE_PREFIX, BUNDLE_ID,
};
