import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {Page} from '@playwright/test';
import {expect,origin} from './browser';
import {samplesRoot} from './environment';

export async function entraLogin(page:Page,uid:'alice'|'carol',app:'HR_ORIGIN'|'ALUMNI_ORIGIN'|'DRUPAL_ORIGIN'|'STUDENT_ORIGIN'|'EVENTS_ORIGIN'='HR_ORIGIN'):Promise<void> {
  const landing=origin(app)+(app==='DRUPAL_ORIGIN'?'/demo/profile?check_logged_in=1':app==='STUDENT_ORIGIN'?'/Student/Profile':app==='EVENTS_ORIGIN'?'/admin/':'/profile');
  const credentials:unknown=JSON.parse(readFileSync(resolve(samplesRoot,'.local','entra-test-users.json'),'utf8'));
  if(typeof credentials!=='object' || credentials===null || !(uid in credentials))
    throw new Error(`Missing dedicated Entra credentials for ${uid}; use the protected local credential file.`);
  const entry:unknown=Reflect.get(credentials,uid);
  if(typeof entry!=='object' || entry===null || !('upn' in entry) || typeof entry.upn!=='string'
      || !('password' in entry) || typeof entry.password!=='string')
    throw new Error(`Invalid dedicated Entra credential entry for ${uid}.`);
  await expect(page,'Expected the real Entra authorization endpoint').toHaveURL(/^https:\/\/login\.microsoftonline\.com\//);
  await expect(page.locator('input[name=loginfmt]'),'Entra username form was not shown').toBeVisible();
  await page.locator('input[name=loginfmt]').fill(entry.upn);
  await page.locator('#idSIButton9').click();
  await expect(page.locator('input[name=passwd]'),'Entra password form unavailable; check federation or tenant policy').toBeVisible();
  await page.locator('input[name=passwd]').fill(entry.password);
  await page.locator('#idSIButton9').click();
  const deadline=Date.now()+60_000;
  while(Date.now()<deadline) {
    if(page.url()===landing) return;
    const error=page.locator('#passwordError, #usernameError, #service_exception_message');
    if(await error.first().isVisible()) throw new Error(`Entra sign-in rejected: ${await error.first().innerText()}`);
    if(await page.getByRole('heading',{name:"Let's keep your account secure",exact:true}).isVisible()
        || await page.getByText('More information required',{exact:true}).isVisible()
        || await page.getByText('Approve sign in request',{exact:true}).isVisible())
      throw new Error('Tenant requires MFA/enrollment. Complete an interactive browser validation; do not disable tenant policy.');
    const stay=page.locator('#idBtn_Back');
    if(await stay.isVisible()) await stay.click();
    const accept=page.getByRole('button',{name:'Accept',exact:true});
    if(await accept.isVisible()) await accept.click();
    if(page.url().startsWith(origin(app)+'/login-error') || await page.getByTestId('login-error').isVisible())
      throw new Error(`OIDC callback failed (${app}); inspect the protected application log for the explicit profile/token error.`);
    if(await page.getByRole('heading',{name:'Whitelabel Error Page',exact:true}).isVisible())
      throw new Error('Callback returned an error; inspect the protected application log. Do not retain the callback URL or authorization code.');
    await page.waitForTimeout(300);
  }
  throw new Error(`Entra did not return to ${app}. Check MFA, consent, federation, profile requirements and the explicit network allow-list.`);
}
