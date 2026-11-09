import {test,expect,origin,casLogin} from '../support/browser';

test.skip(process.env.DEMO_AUTH==='entra' || process.env.ALUMNI_AUTH==='entra','HR or Alumni Entra OIDC has no CAS back-channel cross-app logout.');

test('UC-05 logout invalidates the participating UC-01 CAS app session',async({page,context})=>{
  const hr=origin('HR_ORIGIN'),alumni=origin('ALUMNI_ORIGIN');
  await page.goto(hr+'/login'); await casLogin(page,'alice');
  await expect(page).toHaveURL(hr+'/profile');
  const second=await context.newPage();
  await second.goto(alumni+'/login');
  await expect(second).toHaveURL(alumni+'/profile');
  await expect(second.getByTestId('uid')).toHaveText('alice');
  await second.getByRole('button',{name:'Sign out'}).click();
  await second.waitForURL(alumni+'/');
  await page.goto(hr+'/profile');
  await expect(page.locator('#username')).toBeVisible();
});

test('UC-01 logout revokes the UC-05 phpCAS session through its persisted signout callback',async({page,context})=>{
  const hr=origin('HR_ORIGIN'),alumni=origin('ALUMNI_ORIGIN');
  await page.goto(alumni+'/login'); await casLogin(page,'alice');
  await expect(page).toHaveURL(alumni+'/profile');
  const second=await context.newPage();
  await second.goto(hr+'/login');
  await expect(second).toHaveURL(hr+'/profile');
  await second.getByRole('button',{name:'Sign out'}).click();
  await second.waitForURL(hr+'/');
  await page.goto(alumni+'/profile');
  await expect(page.locator('#username')).toBeVisible();
});
