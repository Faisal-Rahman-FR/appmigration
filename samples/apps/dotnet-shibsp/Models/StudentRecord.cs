using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace Demo.StudentRecords.Models
{
    public sealed class StudentRecord
    {
        public string Eppn { get; set; }
        public string StudentNumber { get; set; }
        public string Program { get; set; }
        public string Status { get; set; }
    }
    public sealed class StudentRecordRepository
    {
        public IReadOnlyList<StudentRecord> All(string path)
        {
            var rows = new JavaScriptSerializer().Deserialize<List<StudentRecord>>(File.ReadAllText(path));
            if (rows == null || rows.Select(r => r.Eppn).Distinct().Count() != rows.Count)
                throw new InvalidDataException("Invalid student seed.");
            return rows.AsReadOnly();
        }
    }
    public sealed class ProfileModel
    {
        public Identity.TrustedSpIdentity Identity { get; set; }
        public StudentRecord Record { get; set; }
    }
}
