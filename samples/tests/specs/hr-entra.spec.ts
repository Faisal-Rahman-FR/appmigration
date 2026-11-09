import {test,expect,origin,healthy} from '../support/browser';
import {entraLogin} from '../support/entra';

test.skip(process.env.DEMO_AUTH!=='entra','Dedicated real-tenant HR tests run only in Entra mode.');

test('UC-01 HR Entra: live discovery and anonymous OIDC challenge',async({page})=>{
  const app=origin('HR_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/');
  await expect(page.getByRole('link',{name:'Sign in with Microsoft Entra ID'})).toBeVisible();
  await page.goto(app+'/profile');
  const authorization=new URL(page.url());
  expect(authorization.origin).toBe('https://login.microsoftonline.com');
  expect(authorization.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/oauth2/v2.0/authorize`);
  expect(authorization.searchParams.get('redirect_uri')).toBe(app+'/login/oauth2/code/entra');
  expect(authorization.searchParams.get('code_challenge_method')).toBe('S256');
  for(const name of ['state','nonce','code_challenge']) expect(authorization.searchParams.get(name)).toBeTruthy();
});

test('UC-01 HR Entra: PKCE, employee profile, admin access and session-ending logout',async({page,context})=>{
  const app=origin('HR_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/login');
  const authorization=new URL(page.url());
  expect(authorization.origin).toBe('https://login.microsoftonline.com');
  expect(authorization.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/oauth2/v2.0/authorize`);
  expect(authorization.searchParams.get('redirect_uri')).toBe(app+'/login/oauth2/code/entra');
  expect(authorization.searchParams.get('code_challenge_method')).toBe('S256');
  for(const name of ['state','nonce','code_challenge']) expect(authorization.searchParams.get(name)).toBeTruthy();
  await entraLogin(page,'alice');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('employeeNumber')).toHaveText('10001');
  await expect(page.getByTestId('memberOf')).toHaveText('[hr-admins]');
  await expect(page.getByTestId('mail')).toHaveText('hr-recipe-admin@MngEnvMCAP536603.onmicrosoft.com');
  const session=(await context.cookies(app)).find(cookie=>cookie.name==='JSESSIONID');
  expect(session).toBeDefined();
  const denied=await page.request.post(app+'/logout',{maxRedirects:0});
  expect(denied.status()).toBe(403);
  const admin=await page.goto(app+'/admin');
  expect(admin?.status()).toBe(200);
  await expect(page.getByRole('heading',{name:'HR administration'})).toBeVisible();
  await page.goto(app+'/profile');
  await expect(page.locator('input[name=_csrf]')).toHaveCount(1);
  await page.getByRole('button',{name:'Sign out'}).click();
  await expect(page).toHaveURL(app+'/');
  const replay=await page.request.get(app+'/profile',{
    headers:{Cookie:`JSESSIONID=${session?.value}`},maxRedirects:0,
  });
  expect(replay.status()).toBe(302);
  expect(replay.headers().location).toBe(app+'/oauth2/authorization/entra');
});

test('UC-01 HR Entra: base member signs in but receives 403 for admin and CAS SLO',async({page})=>{
  const app=origin('HR_ORIGIN');
  await page.goto(app+'/login');
  await entraLogin(page,'carol');
  await expect(page.getByTestId('uid')).toHaveText('carol');
  await expect(page.getByTestId('employeeNumber')).toHaveText('10003');
  await expect(page.getByTestId('memberOf')).toHaveText('[member]');
  expect((await page.goto(app+'/admin'))?.status()).toBe(403);
  expect((await page.goto(app+'/slo'))?.status()).toBe(403);
  await page.goto(app+'/profile');
  await page.getByRole('button',{name:'Sign out'}).click();
  await expect(page).toHaveURL(app+'/');
});
