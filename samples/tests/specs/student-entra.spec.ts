import {test,expect,origin} from '../support/browser';
import {entraLogin} from '../support/entra';

test.describe('UC-03 Student Records: native IIS Shibboleth SP with Entra ID as the IdP',()=>{
  test.skip(process.env.RUN_DOTNET_TESTS!=='1' || process.env.STUDENT_AUTH!=='entra','Windows IIS/SP endpoint in Entra mode only: set RUN_DOTNET_TESTS=1 and STUDENT_AUTH=entra.');
  const needsAutomatedLogin='Automated password sign-in is impossible once MFA is enrolled; set ENTRA_AUTOMATED_LOGIN=1 only for users without MFA.';

  test('readiness, anonymous SAML challenge and non-public SP status',async({page})=>{
    const app=origin('STUDENT_ORIGIN');
    for(const [path,status] of [['/healthz','ok'],['/readyz','ready']]) {
      const response=await page.request.get(app+path,{maxRedirects:0});
      expect(response.status()).toBe(200);
      expect(await response.json()).toMatchObject({status});
    }
    await page.goto(app+'/Student/Profile');
    const request=new URL(page.url());
    expect(request.origin).toBe('https://login.microsoftonline.com');
    expect(request.pathname).toBe(`/${process.env.ENTRA_TENANT_ID}/saml2`);
    expect(request.searchParams.get('SAMLRequest')).toBeTruthy();
    expect((await page.request.get(app+'/Shibboleth.sso/Status',{maxRedirects:0})).status()).toBe(403);
  });

  test('HTTP identity header spoof cannot establish a trusted SP session',async({request})=>{
    const app=origin('STUDENT_ORIGIN');
    const headers={upn:'hr-recipe-admin@spoof.invalid',uid:'alice',roles:'staff',eppn:'bob@demo.test',affiliation:'staff',
      'Shib-Session-ID':'fake','Shib-Identity-Provider':`https://sts.windows.net/${process.env.ENTRA_TENANT_ID}/`,HTTP_UPN:'x',HTTP_ROLES:'staff'};
    for(const path of ['/Student/Profile','/Student/Registrar','/Student/Records']) {
      const response=await request.get(app+path,{maxRedirects:0,headers});
      expect([302,303,401,403]).toContain(response.status());
      expect(await response.text()).not.toContain('S10004');
    }
  });

  test('student: own records only, denied registrar, global logout ends Entra session',async({page})=>{
    test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
    const app=origin('STUDENT_ORIGIN');
    await page.goto(app+'/Student/Profile'); await entraLogin(page,'carol','STUDENT_ORIGIN');
    await expect(page.getByTestId('upn')).toHaveText(/^hr-recipe-member@.+\.onmicrosoft\.com$/i);
    await expect(page.getByTestId('affiliation')).toHaveText('student');
    await expect(page.getByTestId('studentNumber')).toHaveText('S10003');
    await page.getByRole('link',{name:'My records'}).click();
    await expect(page.getByText('S10003')).toBeVisible();
    await expect(page.getByText('S10004')).toHaveCount(0);
    expect((await page.goto(app+'/Student/Registrar'))?.status()).toBe(403);
    await page.goto(app+'/Student/Profile');
    await page.getByRole('link',{name:'Sign out'}).click();
    await expect(page.getByText('Logout completed successfully.')).toBeVisible();
    await page.goto(app+'/Student/Profile');
    await expect(page).toHaveURL(/^https:\/\/login\.microsoftonline\.com\//);
    await expect(page.locator('input[name=loginfmt]')).toBeVisible();
  });

  test('staff: registrar can view all synthetic records',async({page})=>{
    test.skip(process.env.ENTRA_AUTOMATED_LOGIN!=='1',needsAutomatedLogin);
    const app=origin('STUDENT_ORIGIN');
    await page.goto(app+'/Student/Profile'); await entraLogin(page,'alice','STUDENT_ORIGIN');
    await expect(page.getByTestId('affiliation')).toHaveText('staff');
    await page.getByRole('link',{name:'Registrar workspace'}).click();
    await expect(page.getByRole('heading',{name:'Registrar workspace'})).toBeVisible();
    await page.getByRole('link',{name:'All synthetic records'}).click();
    await expect(page.getByText('S10003')).toBeVisible();
    await expect(page.getByText('S10004')).toBeVisible();
  });
});
