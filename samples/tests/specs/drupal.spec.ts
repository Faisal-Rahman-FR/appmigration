import {test,expect,origin,samlLogin,healthy} from '../support/browser';

test.skip(process.env.DRUPAL_AUTH==='entra','Legacy Drupal assertions run only against the Shibboleth IdP.');

test('UC-04 Drupal: username-linked SAML attributes, editor and logout',async({page})=>{
  const app=origin('DRUPAL_ORIGIN');
  await healthy(page,app);
  await page.goto(app+'/saml/login'); await samlLogin(page,'alice');
  await expect(page).toHaveURL(app+'/demo/profile?check_logged_in=1');
  await expect(page.getByTestId('uid')).toHaveText('alice');
  await expect(page.getByTestId('mail')).toHaveText('alice@demo.test');
  await expect(page.getByTestId('eduPersonAffiliation')).toContainText('faculty');
  await expect(page.getByTestId('roles')).toContainText('editor');
  await page.getByRole('link',{name:'Editor workspace'}).click();
  await expect(page.getByRole('heading',{name:'Editor workspace'})).toBeVisible();
  await page.goto(app+'/demo/profile');
  await page.getByRole('link',{name:'Sign out',exact:true}).click();
  const confirm=page.getByRole('button',{name:/log out|sign out/i});
  if(await confirm.isVisible()) await confirm.click();
  await page.waitForURL(url=>!url.pathname.startsWith('/demo/profile'));
  await page.goto(app+'/saml/login');
  await expect(page.locator('input[name=j_username]')).toBeVisible();
});
test('UC-04 Drupal: student account links but is not editor',async({page})=>{
  const app=origin('DRUPAL_ORIGIN');
  await page.goto(app+'/saml/login'); await samlLogin(page,'carol');
  await expect(page).toHaveURL(app+'/demo/profile?check_logged_in=1');
  await expect(page.getByTestId('uid')).toHaveText('carol');
  await expect(page.getByTestId('roles')).not.toContainText('editor');
  expect((await page.goto(app+'/demo/editor'))?.status()).toBe(403);
});
