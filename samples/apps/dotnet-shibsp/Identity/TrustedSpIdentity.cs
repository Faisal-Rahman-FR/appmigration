using System;
using System.Collections.Generic;
using System.Configuration;
using System.Linq;
using System.Text;
using System.Web;

namespace Demo.StudentRecords.Identity
{
    public sealed class TrustedSpIdentity
    {
        public string Eppn { get; private set; }
        public string Upn { get; private set; }
        public string DisplayName { get; private set; }
        public IReadOnlyCollection<string> Affiliations { get; private set; }
        public bool IsStudent { get { return Affiliations.Contains("student", StringComparer.Ordinal); } }
        public bool IsRegistrar { get { return Affiliations.Contains("staff", StringComparer.Ordinal); } }

        private TrustedSpIdentity() { }

        public static TrustedSpIdentity Require(HttpRequestBase request)
        {
            // These are native IIS SP server variables. Never add HTTP_* or Headers fallbacks.
            var variables = request.ServerVariables;
            var mode = ConfigurationManager.AppSettings["AuthMode"] ?? "shibboleth";
            if (mode != "shibboleth" && mode != "entra")
                throw new HttpException(500, "AuthMode must be shibboleth or entra.");
            if (string.IsNullOrWhiteSpace(variables["Shib-Session-ID"]) ||
                variables["Shib-Identity-Provider"] != ConfigurationManager.AppSettings["IdpEntityId"])
                throw new HttpException(401, "A trusted Shibboleth SP session is required.");
            if (mode == "entra") return RequireEntra(variables);
            var eppn = Split(variables["eppn"]);
            if (eppn.Count != 1 || !eppn[0].EndsWith("@" + ConfigurationManager.AppSettings["DemoScope"], StringComparison.Ordinal))
                throw new HttpException(403, "A single scoped principal is required.");
            return new TrustedSpIdentity {
                Eppn=eppn[0], DisplayName=Split(variables["displayName"]).FirstOrDefault() ?? eppn[0],
                Affiliations=Split(variables["unscoped-affiliation"]).AsReadOnly()
            };
        }

        // Entra has no eduPerson scope: trust the tenant-bound issuer, require a UPN in the tenant domain, and keep the legacy record key derived from mailNickname.
        private static TrustedSpIdentity RequireEntra(System.Collections.Specialized.NameValueCollection variables)
        {
            var upn = Split(variables["upn"]);
            if (upn.Count != 1 || !upn[0].EndsWith("@" + ConfigurationManager.AppSettings["TenantDomain"], StringComparison.OrdinalIgnoreCase))
                throw new HttpException(403, "A single principal in the tenant domain is required.");
            var uid = Split(variables["uid"]);
            if (uid.Count != 1 || !System.Text.RegularExpressions.Regex.IsMatch(uid[0], "^[a-z0-9._-]+$"))
                throw new HttpException(403, "A single uid claim is required.");
            return new TrustedSpIdentity {
                Eppn=uid[0] + "@" + ConfigurationManager.AppSettings["DemoScope"], Upn=upn[0],
                DisplayName=Split(variables["displayName"]).FirstOrDefault() ?? upn[0],
                Affiliations=Split(variables["roles"]).AsReadOnly()
            };
        }

        internal static List<string> Split(string value)
        {
            var result = new List<string>();
            var item = new StringBuilder();
            bool escaped = false;
            foreach (char c in value ?? "")
            {
                if (escaped) { item.Append(c); escaped=false; }
                else if (c == '\\') escaped=true;
                else if (c == ';') { if (item.Length > 0) result.Add(item.ToString()); item.Clear(); }
                else item.Append(c);
            }
            if (escaped) item.Append('\\');
            if (item.Length > 0) result.Add(item.ToString());
            return result;
        }
    }
}
