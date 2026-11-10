import {test as base,expect,Page} from '@playwright/test';
import {origin,originKeys,password} from './environment';

export const test=base.extend({
  context:async({context},use)=>{
    const allowed=new Set([...originKeys,...(process.env.RUN_DOTNET_TESTS==='1'?['STUDENT_ORIGIN']:[])].map(origin));
    if(process.env.DEMO_AUTH==='entra' || process.env.ALUMNI_AUTH==='entra' || process.env.DRUPAL_AUTH==='entra' || process.env.STUDENT_AUTH==='entra' || process.env.EVENTS_AUTH==='entra') {
      for(const host of ['login.microsoftonline.com','aadcdn.msauth.net','aadcdn.msftauth.net','logincdn.msauth.net'])
        allowed.add(`https://${host}`);
    }
    await context.route('**/*',route=>{
      const url=new URL(route.request().url());
      return allowed.has(url.origin)?route.continue():route.abort('blockedbyclient');
    });
    await use(context);
  },
});
export {expect,origin};
export async function casLogin(page:Page,uid:string):Promise<void> {
  await expect(page).toHaveURL(new RegExp('^'+origin('CAS_ORIGIN').replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'/cas/login'));
  await page.locator('#username').fill(uid);
  await page.locator('#password').fill(password(uid));
  await page.locator('button[type=submit],input[type=submit]').first().click();
}
export async function samlLogin(page:Page,uid:string):Promise<void> {
  await expect(page).toHaveURL(new RegExp('^'+origin('IDP_ORIGIN').replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'/idp/'));
  await page.locator('input[name=j_username]').fill(uid);
  await page.locator('input[name=j_password]').fill(password(uid));
  await page.locator('button[name=_eventId_proceed],input[name=_eventId_proceed]').first().click();
}
export async function healthy(page:Page,appOrigin:string):Promise<void> {
  for(const [path,status] of [['/healthz','ok'],['/readyz','ready']]) {
    const response=await page.request.get(appOrigin+path,{maxRedirects:0});
    expect(response.status()).toBe(200);
    expect(await response.json()).toMatchObject({status});
  }
}
