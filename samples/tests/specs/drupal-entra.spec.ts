import {test,expect,origin,healthy} from '../support/browser';
import {entraLogin} from '../support/entra';

test.skip(process.env.DRUPAL_AUTH!=='entra','Dedicated real-tenant Drupal tests run only in Entra mode.');
const needsAutomatedLogin='Automated password sign-in is impossible once MFA is enrolled; set ENTRA_AUTOMATED_LOGIN=1 only for users without MFA.';

test('UC-04 Drupal Entra: readiness and anonymous SAML challenge',async({page})=>{
  const app=origin('DRUPAL_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/');
  await expect(page.getByRole('link',{name:'Sign in with Microsoft Entra ID'})).toBeVisible();
  await page.goto(app+'/saml/login');
  const request=new URL(page.url());
  expect(request.origin).toBe('https://login.microsoftonline.com');
  expect(request.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/saml2`);
  expect(request.searchParams.get('SAMLRequest')).toBeTruthy();
});

test('UC-04 Drupal Entra: faculty links by uid, becomes editor and signs out',async({page})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('DRUPAL_ORIGIN');
  await page.goto(app+'/saml/login'); await entraLogin(page,'alice','DRUPAL_ORIGIN');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('mail')).toHaveText(/^hr-recipe-admin@.+\.onmicrosoft\.com$/i);
  await expect(page.getByTestId('appRoles')).toContainText('faculty');
  await expect(page.getByTestId('roles')).toContainText('editor');
  expect((await page.goto(app+'/demo/editor'))?.status()).toBe(200);
  await page.goto(app+'/demo/profile');
  await page.getByRole('link',{name:'Sign out',exact:true}).click();
  const confirm=page.getByRole('button',{name:/log out|sign out/i});
  if(await confirm.isVisible()) await confirm.click();
  await page.goto(app+'/demo/profile');
  await expect(page).toHaveURL(/^https:\/\/login\.microsoftonline\.com\/|\/user\/login|\/demo$/);
});

test('UC-04 Drupal Entra: base member signs in but is not editor',async({page})=>{
  test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
  const app=origin('DRUPAL_ORIGIN');
  await page.goto(app+'/saml/login'); await entraLogin(page,'carol','DRUPAL_ORIGIN');
  await expect(page.getByTestId('uid')).toHaveText('carol');
  await expect(page.getByTestId('appRoles')).toHaveText('member');
  await expect(page.getByTestId('roles')).not.toContainText('editor');
  expect((await page.goto(app+'/demo/editor'))?.status()).toBe(403);
});
