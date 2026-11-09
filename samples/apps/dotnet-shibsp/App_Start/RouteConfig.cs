using System.Web.Mvc;
using System.Web.Routing;
namespace Demo.StudentRecords
{
    public static class RouteConfig
    {
        public static void RegisterRoutes(RouteCollection routes)
        {
            routes.IgnoreRoute("{resource}.axd/{*pathInfo}");
            routes.IgnoreRoute("Shibboleth.sso/{*pathInfo}");
            routes.MapRoute("health", "healthz", new { controller="Home", action="Health" });
            routes.MapRoute("ready", "readyz", new { controller="Home", action="Ready" });
            routes.MapRoute("default", "{controller}/{action}", new { controller="Home", action="Index" });
        }
    }
}
