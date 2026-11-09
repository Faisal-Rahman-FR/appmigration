using System.Linq;
using System.Web.Mvc;
using Demo.StudentRecords.Identity;
using Demo.StudentRecords.Models;

namespace Demo.StudentRecords.Controllers
{
    public sealed class StudentController : Controller
    {
        protected override void OnActionExecuting(ActionExecutingContext context)
        {
            Response.Cache.SetCacheability(System.Web.HttpCacheability.NoCache);
            Response.Cache.SetNoStore();
            base.OnActionExecuting(context);
        }
        public new ActionResult Profile()
        {
            var identity=TrustedSpIdentity.Require(Request);
            var record=new StudentRecordRepository().All(Server.MapPath("~/App_Data/student-records.json")).SingleOrDefault(r=>r.Eppn == identity.Eppn);
            return View(new ProfileModel { Identity=identity, Record=record });
        }
        public ActionResult Records()
        {
            var identity=TrustedSpIdentity.Require(Request);
            if (!identity.IsStudent && !identity.IsRegistrar) return new HttpStatusCodeResult(403);
            var rows=new StudentRecordRepository().All(Server.MapPath("~/App_Data/student-records.json"));
            return View(rows.Where(r=>identity.IsRegistrar || r.Eppn == identity.Eppn).ToList());
        }
        public ActionResult Registrar()
        {
            if (!TrustedSpIdentity.Require(Request).IsRegistrar) return new HttpStatusCodeResult(403);
            return View();
        }
    }
}
