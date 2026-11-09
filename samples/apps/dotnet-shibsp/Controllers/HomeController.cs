using System;
using System.IO;
using System.Net;
using System.Configuration;
using System.Web.Mvc;
using Demo.StudentRecords.Models;

namespace Demo.StudentRecords.Controllers
{
    public sealed class HomeController : Controller
    {
        public ActionResult Index() { return View(); }
        public ActionResult Health() { return Json(new { status="ok" }, JsonRequestBehavior.AllowGet); }
        public ActionResult Ready()
        {
            try
            {
                new StudentRecordRepository().All(Server.MapPath("~/App_Data/student-records.json"));
                var request = (HttpWebRequest)WebRequest.Create(ConfigurationManager.AppSettings["SpStatusUrl"]);
                request.Proxy=null;
                request.Timeout = 4000; request.AllowAutoRedirect=false;
                using (var response = (HttpWebResponse)request.GetResponse())
                    if (response.StatusCode != HttpStatusCode.OK) throw new IOException("SP unavailable");
                return Json(new { status="ready" }, JsonRequestBehavior.AllowGet);
            }
            catch (Exception)
            {
                Response.StatusCode=503;
                return Json(new { status="notReady" }, JsonRequestBehavior.AllowGet);
            }
        }
    }
}
