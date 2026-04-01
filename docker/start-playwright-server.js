const { chromium } = require('playwright');

const port = parseInt(process.env.PLAYWRIGHT_SERVER_PORT || '3000', 10);
const headless = process.env.PLAYWRIGHT_HEADLESS === '1';

(async () => {
  const server = await chromium.launchServer({
    host: '0.0.0.0',
    port,
    headless,
    chromiumSandbox: false,
  });
  // Print the ws endpoint path so the host can reconstruct the full URL
  const wsEndpoint = server.wsEndpoint();
  const wsPath = new URL(wsEndpoint).pathname;
  console.log(`PLAYWRIGHT_WS_PATH=${wsPath}`);

  process.on('SIGTERM', async () => {
    await server.close();
    process.exit(0);
  });
})();
