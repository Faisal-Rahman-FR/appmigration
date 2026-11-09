import {test,expect,origin,casLogin,healthy} from '../support/browser';

test.skip(process.env.ALUMNI_AUTH==='entra','Legacy Alumni assertions run only in CAS mode.');

test('UC-05 Alumni: phpCAS attributes, DB profile, role and logout',async({page})=>{
  const app=origin('ALUMNI_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/login'); await casLogin(page,'erin');
  await expect(page).toHaveURL(app+'/profile');
  await expect(page.getByTestId('uid')).toHaveText('erin');
  await expect(page.getByTestId('mail')).toHaveText('erin@demo.test');
  await expect(page.getByTestId('eduPersonAffiliation')).toContainText('alum');
  await expect(page.getByTestId('biography')).toContainText('reunion');
  await page.getByRole('link',{name:'Alumni members'}).click();
  await expect(page.getByText('Erin Ellis (2018)')).toBeVisible();
  await page.goto(app+'/profile'); await page.getByRole('button',{name:'Sign out'}).click();
  await page.waitForURL(app+'/');
  await page.getByRole('link',{name:'Sign in with CAS'}).click();
  await expect(page.locator('#username')).toBeVisible();
});
test('UC-05 Alumni: non-alum is denied directory',async({page})=>{
  await page.goto(origin('ALUMNI_ORIGIN')+'/login'); await casLogin(page,'carol');
  await expect(page).toHaveURL(origin('ALUMNI_ORIGIN')+'/profile');
  const response=await page.goto(origin('ALUMNI_ORIGIN')+'/directory');
  expect(response?.status()).toBe(403);
});
