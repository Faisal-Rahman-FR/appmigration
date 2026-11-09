import {test,expect,origin,samlLogin,healthy} from '../support/browser';

test.describe('UC-03 Student Records: Windows Framework4.8 and native IIS Shibboleth SP',()=>{
  test.skip(process.env.RUN_DOTNET_TESTS!=='1','Windows IIS/SP endpoint unavailable unless explicitly opted in with RUN_DOTNET_TESTS=1; not a passing test.');
  test.skip(process.env.STUDENT_AUTH==='entra','Legacy Student assertions run only against the Shibboleth IdP.');
  test('student attributes, own records, denied registrar and SP logout',async({page})=>{
    const app=origin('STUDENT_ORIGIN');
    await healthy(page,app);
    await page.goto(app+'/Student/Profile'); await samlLogin(page,'carol');
    await expect(page.getByTestId('eppn')).toHaveText('carol@demo.test');
    await expect(page.getByTestId('affiliation')).toContainText('student');
    await expect(page.getByTestId('studentNumber')).toHaveText('S10003');
    await page.getByRole('link',{name:'My records'}).click();
    await expect(page.getByText('S10003')).toBeVisible();
    await expect(page.getByText('S10004')).toHaveCount(0);
    expect((await page.goto(app+'/Student/Registrar'))?.status()).toBe(403);
    await page.goto(app+'/Student/Profile');
    await page.getByRole('link',{name:'Sign out'}).click();
    await expect(page).not.toHaveURL(app+'/Student/Profile');
    await page.goto(app+'/Student/Profile');
    await expect(page.locator('input[name=j_username]')).toBeVisible();
  });
  test('staff registrar can view all synthetic records',async({page})=>{
    const app=origin('STUDENT_ORIGIN');
    await page.goto(app+'/Student/Profile'); await samlLogin(page,'bob');
    await page.getByRole('link',{name:'Registrar workspace'}).click();
    await expect(page.getByRole('heading',{name:'Registrar workspace'})).toBeVisible();
    await page.getByRole('link',{name:'All synthetic records'}).click();
    await expect(page.getByText('S10003')).toBeVisible();
    await expect(page.getByText('S10004')).toBeVisible();
  });
  test('HTTP identity header spoof cannot establish a trusted SP session',async({request})=>{
    const response=await request.get(origin('STUDENT_ORIGIN')+'/Student/Profile',{
      maxRedirects:0,
      headers:{eppn:'bob@demo.test',affiliation:'staff','Shib-Session-ID':'fake','Shib-Identity-Provider':origin('IDP_ORIGIN')+'/idp/shibboleth','HTTP_EPPN':'bob@demo.test'},
    });
    expect([302,303,401,403]).toContain(response.status());
    expect(await response.text()).not.toContain('data-testid="eppn">bob@demo.test');
  });
});
