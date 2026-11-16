const { chromium, devices } = require('playwright');
const path = require('node:path');
const fs = require('node:fs');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ ...devices['Pixel 7'] });
  const page = await context.newPage();
  const failures = [];
  const pages = [
    ['/', 'Ashiana Public School'],
    ['/help-support.html', 'Help & Support'],
    ['/privacy-policy.html', 'Privacy Policy'],
    ['/terms-of-service.html', 'Terms of Service'],
    ['/404.html', 'Page Not Found'],
    ['/empty-state.html', 'No Records Available']
  ];

  for (const [url, titlePart] of pages) {
    const response = await page.goto('http://127.0.0.1:4173' + url, { waitUntil: 'domcontentloaded' });
    if (!response || !response.ok()) failures.push(url + ': HTTP response not OK');
    const title = await page.title();
    if (!title.includes(titlePart)) failures.push(url + ': unexpected title: ' + title);
    const meta = await page.locator('meta[name="description"]').getAttribute('content');
    if (!meta || !meta.trim()) failures.push(url + ': missing meta description');
    const icon = await page.locator('link[rel~="icon"]').getAttribute('href');
    if (!icon) failures.push(url + ': missing favicon reference');
    const refs = await page.locator('a[href], img[src], script[src], link[href]').evaluateAll(nodes => nodes.map(node => node.getAttribute('href') || node.getAttribute('src')).filter(value => value && (value.startsWith('./') || value.endsWith('.html') || value.endsWith('.svg'))));
    const broken = refs.filter(value => {
      const pathname = new URL(value, 'http://127.0.0.1:4173').pathname;
      const target = path.join(process.cwd(), decodeURIComponent(pathname === '/' ? '/index.html' : pathname));
      return !fs.existsSync(target);
    });
    if (broken.length) failures.push(url + ': missing local references ' + broken.join(', '));
    const dimensions = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      page: document.documentElement.scrollWidth,
      body: document.body.scrollWidth
    }));
    if (dimensions.page > dimensions.viewport + 1 || dimensions.body > dimensions.viewport + 1) {
      failures.push(url + ': horizontal overflow ' + JSON.stringify(dimensions));
    }
  }

  await page.goto('http://127.0.0.1:4173/help-support.html', { waitUntil: 'domcontentloaded' });
  const menu = page.locator('details.mobile-nav');
  if (!(await menu.count())) failures.push('Help page: mobile navigation menu missing');
  else {
    await menu.locator('summary').click();
    if (!(await menu.locator('.menu-links a').first().isVisible())) failures.push('Help page: mobile menu did not open');
  }

  for (const [role, expected] of [
    ['admin', 'Administrator Login'],
    ['teacher', 'Teacher Login'],
    ['staff', 'Staff Login'],
    ['student', 'Student Login']
  ]) {
    await page.goto('http://127.0.0.1:4173/?login=' + role, { waitUntil: 'domcontentloaded' });
    if (!(await page.title()).includes(expected)) failures.push('Role route ' + role + ': incorrect page title');
  }

  await page.goto('http://127.0.0.1:4173/', { waitUntil: 'domcontentloaded' });
  for (const href of ['mailto:ashianapublicschool@gmail.com', 'tel:+919872500460']) {
    if (!(await page.locator('a[href="' + href + '"]').count())) failures.push('Login page: missing contact link ' + href);
  }

  await browser.close();
  if (failures.length) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
  console.log('Mobile viewport, SEO metadata, favicon, Help menu and contact-link smoke tests passed.');
})().catch(error => { console.error(error); process.exit(1); });
