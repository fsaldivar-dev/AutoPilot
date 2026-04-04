const {
  createSession, deleteSession,
  findAndTap, waitForElement, saveScreenshot,
  enrollBiometric, sendBiometricMatch,
  terminateApp, activateApp, sleep,
  EVIDENCE_DIR,
} = require('./appium-helpers');

async function main() {
  const sessionId = await createSession();
  try {
    // Enroll Face ID via simctl
    enrollBiometric(false);
    enrollBiometric(true);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-biometric-step1.png`);

    // Restart app to pick up biometric enrollment
    await terminateApp(sessionId);
    await sleep(500);
    await activateApp(sessionId);
    await sleep(1000);

    await waitForElement(sessionId, 'Desbloquear con biometría', 10000);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-biometric-step2.png`);

    await findAndTap(sessionId, 'Desbloquear con biometría');
    await sleep(500);

    // Send Face ID match via simctl
    sendBiometricMatch(true);
    await sleep(1500);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-biometric-step3.png`);
  } finally {
    await deleteSession(sessionId);
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
