const {
  createSession, deleteSession,
  findAndTap, waitForElement, saveScreenshot,
  terminateApp, activateApp, sleep,
  EVIDENCE_DIR,
} = require('./appium-helpers');

async function main() {
  const sessionId = await createSession();
  try {
    // Clean launch
    await terminateApp(sessionId);
    await sleep(500);
    await activateApp(sessionId);
    await sleep(1000);

    await waitForElement(sessionId, 'Explorea', 10000);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-login-step1.png`);

    await findAndTap(sessionId, 'Usar código');
    await waitForElement(sessionId, 'Ingresa tu código', 5000);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-login-step2.png`);

    await findAndTap(sessionId, '1');
    await findAndTap(sessionId, '2');
    await findAndTap(sessionId, '3');
    await findAndTap(sessionId, '4');
    await findAndTap(sessionId, 'Confirmar');
    await waitForElement(sessionId, 'Inicio', 5000);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-login-step3.png`);

    await findAndTap(sessionId, 'Aventura');
    await sleep(500);
    await saveScreenshot(sessionId, `${EVIDENCE_DIR}/wda-login-step4.png`);
  } finally {
    await deleteSession(sessionId);
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
