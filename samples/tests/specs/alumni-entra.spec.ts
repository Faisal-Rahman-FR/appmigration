import {test,expect,origin,healthy} from '../support/browser';
import {entraLogin} from '../support/entra';

test.skip(process.env.ALUMNI_AUTH!=='entra','Dedicated real-tenant Alumni tests run only in Entra mode.');
const needsAutomatedLogin='Automated password sign-in is impossible once MFA is enrolled; set ENTRA_AUTOMATED_LOGIN=1 only for users without MFA.';

test('UC-05 Alumni Entra: readiness, anonymous OIDC challenge and disabled back-channel logout',async({page})=>{
  const app=origin('ALUMNI_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/');
  await expect(page.getByRole('link',{name:'Sign in with Microsoft Entra ID'})).toBeVisible();
  await page.goto(app+'/profile');
  const authorization=new URL(page.url());
  expect(authorization.origin).toBe('https://login.microsoftonline.com');
  expect(authorization.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/oauth2/v2.0/authorize`);
  expect(authorization.searchParams.get('client_id')).toBe(process.env.ALUMNI_ENTRA_CLIENT_ID);
  expect(authorization.searchParams.get('redirect_uri')).toBe(app+'/login');
  expect(authorization.searchParams.get('response_type')).toBe('code');
  expect(authorization.searchParams.get('code_challenge_method')).toBe('S256');
  for(const name of ['state','nonce','code_challenge']) expect(authorization.searchParams.get(name)).toBeTruthy();
  expect(authorization.searchParams.get('scope')).toContain('https://graph.microsoft.com/User.Read');
  const slo=await page.request.post(app+'/slo',{form:{logoutRequest:'<LogoutRequest/>'},maxRedirects:0});
  expect(slo.status()).toBe(403);
});

test('UC-05 Alumni Entra: alum profile, directory and session-ending logout',async({page,context})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('ALUMNI_ORIGIN');
  await page.goto(app+'/login'); await entraLogin(page,'alice','ALUMNI_ORIGIN');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('mail')).toHaveText(/^hr-recipe-admin@.+\.onmicrosoft\.com$/i);
  await expect(page.getByTestId('eduPersonAffiliation')).toHaveText('alum');
  await expect(page.getByTestId('biography')).toContainText('Synthetic faculty member');
  await page.getByRole('link',{name:'Alumni members'}).click();
  await expect(page.getByText('Alice Avery (2010)')).toBeVisible();
  const session=(await context.cookies(app)).find(cookie=>cookie.name==='ALUMNI_SESSION');
  expect(session).toBeDefined();
  await page.goto(app+'/profile'); await page.getByRole('button',{name:'Sign out'}).click();
  await expect(page).toHaveURL(app+'/');
  const replay=await page.request.get(app+'/profile',{headers:{Cookie:`ALUMNI_SESSION=${session?.value}`},maxRedirects:0});
  expect(replay.status()).toBe(302);
  expect(replay.headers().location).toMatch(/^https:\/\/login\.microsoftonline\.com\//);
});

test('UC-05 Alumni Entra: base member signs in but is denied the directory',async({page})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('ALUMNI_ORIGIN');
  await page.goto(app+'/login'); await entraLogin(page,'carol','ALUMNI_ORIGIN');
  await expect(page.getByTestId('uid')).toHaveText('carol');
  await expect(page.getByTestId('eduPersonAffiliation')).toHaveText('member');
  expect((await page.goto(app+'/directory'))?.status()).toBe(403);
});
