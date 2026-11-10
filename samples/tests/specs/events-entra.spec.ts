import {test,expect,origin,healthy} from '../support/browser';
import {entraLogin} from '../support/entra';

test.skip(process.env.EVENTS_AUTH!=='entra','Dedicated real-tenant Events tests run only in Entra mode.');
const needsAutomatedLogin='Automated password sign-in is impossible once MFA is enrolled; set ENTRA_AUTOMATED_LOGIN=1 only for users without MFA.';

test('UC-06 Events Entra: readiness, anonymous OIDC challenge and no static bypass',async({page,request})=>{
  const app=origin('EVENTS_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/');
  await expect(page.getByTestId('public-events')).toContainText('Spring Open House');
  await page.goto(app+'/admin/');
  const authorization=new URL(page.url());
  expect(authorization.origin).toBe('https://login.microsoftonline.com');
  expect(authorization.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/oauth2/v2.0/authorize`);
  expect(authorization.searchParams.get('client_id')).toBe(process.env.EVENTS_ENTRA_CLIENT_ID);
  expect(authorization.searchParams.get('redirect_uri')).toBe(app+'/admin/callback.php');
  expect(authorization.searchParams.get('code_challenge_method')).toBe('S256');
  for(const name of ['state','nonce','code_challenge']) expect(authorization.searchParams.get(name)).toBeTruthy();
  const download=await request.get(app+'/admin/download.php?file=attendees.csv',{maxRedirects:0});
  expect(download.status()).toBe(302);
  expect(download.headers().location).toMatch(/^https:\/\/login\.microsoftonline\.com\//);
  const staticFile=await request.get(app+'/admin/exports/attendees.csv',{maxRedirects:0});
  expect(staticFile.status()).toBe(403);
  expect(await staticFile.text()).not.toContain('attendee1@');
});

test('UC-06 Events Entra: admin alice, role table and session-ending logout',async({page})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('EVENTS_ORIGIN');
  await page.goto(app+'/admin/'); await entraLogin(page,'alice','EVENTS_ORIGIN');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('role')).toHaveText('admin');
  expect((await page.request.get(app+'/admin/download.php?file=attendees.csv')).status()).toBe(200);
  await page.getByRole('button',{name:'Sign out'}).click();
  await page.goto(app+'/admin/');
  await expect(page).toHaveURL(/^https:\/\/login\.microsoftonline\.com\//);
});

test('UC-06 Events Entra: carol signs in but is not event staff',async({page})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('EVENTS_ORIGIN');
  await page.goto(app+'/admin/'); await entraLogin(page,'carol','EVENTS_ORIGIN');
  await expect(page.locator('body')).toContainText('not event staff');
});
