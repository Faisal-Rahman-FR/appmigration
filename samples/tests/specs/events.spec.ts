import {test,expect,origin,casLogin,healthy} from '../support/browser';

test.skip(process.env.EVENTS_AUTH==='entra','Legacy mod_auth_cas assertions run only in CAS mode.');
const escaped=(value:string)=>value.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');

test('UC-06 Events: public calendar; admin and static export require CAS',async({page,request})=>{
  const app=origin('EVENTS_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/');
  await expect(page.getByTestId('public-events')).toContainText('Spring Open House');
  for(const path of ['/admin/','/admin/exports/attendees.csv','/admin/download.php?file=attendees.csv']) {
    const response=await request.get(app+path,{maxRedirects:0});
    expect(response.status(),path).toBe(302);
    expect(response.headers().location).toMatch(new RegExp('^'+escaped(origin('CAS_ORIGIN'))+'/cas/login'));
    expect(await response.text()).not.toContain('attendee1@');
  }
});

test('UC-06 Events: admin alice sees everything, edge list guards the static export, logout ends CAS SSO',async({page})=>{
  const app=origin('EVENTS_ORIGIN');
  await page.goto(app+'/admin/'); await casLogin(page,'alice');
  await expect(page).toHaveURL(app+'/admin/');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('role')).toHaveText('admin');
  await expect(page.getByTestId('events')).toContainText('Alumni Mixer');
  expect((await page.goto(app+'/admin/staff.php'))?.status()).toBe(200);
  const download=await page.request.get(app+'/admin/download.php?file=attendees.csv');
  expect(download.status()).toBe(200);
  expect(await download.text()).toContain('attendee1@');
  expect((await page.request.get(app+'/admin/exports/attendees.csv')).status()).toBe(200);
  const noToken=await page.request.post(app+'/admin/status.php',{form:{id:'3',status:'approved'},maxRedirects:0});
  expect(noToken.status()).toBe(403);
  await page.goto(app+'/admin/');
  await page.getByRole('button',{name:'Sign out'}).click();
  const confirm=page.getByRole('button',{name:/log out|sign out/i});
  if(await confirm.isVisible()) await confirm.click();
  await page.goto(app+'/admin/');
  await expect(page.locator('#username')).toBeVisible();
});

test('UC-06 Events: organizer bob sees only own events and is denied admin pages',async({page})=>{
  const app=origin('EVENTS_ORIGIN');
  await page.goto(app+'/admin/'); await casLogin(page,'bob');
  await expect(page.getByTestId('role')).toHaveText('organizer');
  await expect(page.getByTestId('events')).toContainText('Robotics Showcase');
  await expect(page.getByTestId('events')).not.toContainText('Alumni Mixer');
  expect((await page.goto(app+'/admin/staff.php'))?.status()).toBe(403);
  expect((await page.request.get(app+'/admin/download.php?file=attendees.csv')).status()).toBe(403);
  // mod_auth_cas answers 401 (not 403) when an authenticated user is outside the Require user list.
  expect([401,403]).toContain((await page.request.get(app+'/admin/exports/attendees.csv')).status());
});

test('UC-06 Events: carol signs in at CAS but is not event staff',async({page})=>{
  const app=origin('EVENTS_ORIGIN');
  await page.goto(app+'/admin/'); await casLogin(page,'carol');
  await expect(page.locator('body')).toContainText('not event staff');
  expect([401,403]).toContain((await page.request.get(app+'/admin/exports/attendees.csv')).status());
});
