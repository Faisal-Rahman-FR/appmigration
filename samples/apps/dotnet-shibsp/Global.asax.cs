using System.Web;
using System.Web.Mvc;
using System.Web.Routing;

namespace Demo.StudentRecords
{
    public class MvcApplication : HttpApplication
    {
        protected void Application_Start()
        {
            MvcHandler.DisableMvcResponseHeader = true;
            RouteConfig.RegisterRoutes(RouteTable.Routes);
        }
        protected void Application_BeginRequest()
        {
            Response.Headers["X-Content-Type-Options"] = "nosniff";
            Response.Headers["Content-Security-Policy"] = "default-src 'self'; frame-ancestors 'none'; form-action 'self'";
        }
    }
}
