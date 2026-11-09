import {test,expect,origin,casLogin,healthy} from '../support/browser';

test.skip(process.env.DEMO_AUTH==='entra','Legacy HR assertions run only in CAS mode.');

test('UC-01 HR: CAS attributes, exact group role and logout',async({page})=>{
  const app=origin('HR_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/login'); await casLogin(page,'alice');
  await expect(page).toHaveURL(app+'/profile');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('employeeNumber')).toContainText('10001');
  await expect(page.getByTestId('memberOf')).toContainText('cn=hr-admins');
  await page.getByRole('link',{name:'HR administrators'}).click();
  await expect(page.getByRole('heading',{name:'HR administration'})).toBeVisible();
  await page.goto(app+'/profile'); await page.getByRole('button',{name:'Sign out'}).click();
  await page.waitForURL(app+'/');
  await page.getByRole('link',{name:'Sign in with CAS'}).click();
  await expect(page.locator('#username')).toBeVisible();
});
test('UC-01 HR: student cannot enter administrator page',async({page})=>{
  await page.goto(origin('HR_ORIGIN')+'/login'); await casLogin(page,'carol');
  await expect(page).toHaveURL(origin('HR_ORIGIN')+'/profile');
  const response=await page.goto(origin('HR_ORIGIN')+'/admin');
  expect(response?.status()).toBe(403);
});
