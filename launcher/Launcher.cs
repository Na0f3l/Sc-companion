// SC Companion.exe : lanceur de la version publiée (remplace Lancer.vbs ; VBScript disparaît de Windows).
// Compilé par scripts/release.mjs avec le compilateur C# fourni avec Windows (.NET Framework 4), icône icone.ico.
//
//  - service déjà lancé (GET /health répond) : ouvre seulement l'interface ;
//  - sinon démarre le service caché avec node\node.exe (livré) ou le Node du PC, journal dans
//    %LOCALAPPDATA%\SC Companion\service.log, attend qu'il réponde, puis ouvre l'interface dans le navigateur.
// Le lanceur se ferme aussitôt : le service vit seul (icône près de l'horloge, Quit pour l'arrêter).
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;
using System.Windows.Forms;

// Options (développement, tests) : --port <n> (transmis au service), --no-browser (ne pas ouvrir l'interface),
// les autres arguments sont transmis au service tels quels (--game-dir "…", --no-tray…).
static class Launcher
{
    static int Port = 2950;
    static string Url = "http://localhost:2950";

    static bool ServiceUp()
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create(Url + "/health");
            req.Timeout = 500;
            req.Proxy = null;
            using (var res = (HttpWebResponse)req.GetResponse()) return res.StatusCode == HttpStatusCode.OK;
        }
        catch { return false; }
    }

    static void Fail(string msg)
    {
        MessageBox.Show(msg, "SC Companion", MessageBoxButtons.OK, MessageBoxIcon.Error);
        Environment.Exit(1);
    }

    [STAThread]
    static void Main(string[] args)
    {
        bool browser = true;
        string extra = "";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--no-browser") browser = false;
            else if (args[i] == "--port" && i + 1 < args.Length && int.TryParse(args[i + 1], out Port)) i++;
            else extra += " \"" + args[i] + "\"";
        }
        Url = "http://localhost:" + Port;
        if (Port != 2950) extra += " --port " + Port;
        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        if (!ServiceUp())
        {
            if (!File.Exists(Path.Combine(dir, @"interface\dist\index.html")))
                Fail("Interface not found.\nExtract the whole zip, then run SC Companion.exe from the extracted folder.");
            string node = Path.Combine(dir, @"node\node.exe");
            if (!File.Exists(node)) node = "node"; // copie de développement : Node installé sur le PC
            // même dossier de données que le service (service/src/paths.ts : SCC_DATA_DIR pour les tests)
            string data = Environment.GetEnvironmentVariable("SCC_DATA_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SC Companion");
            Directory.CreateDirectory(data);
            string log = Path.Combine(data, "service.log");
            // cmd /c pour envoyer la sortie dans le journal : un tube vers ce lanceur casserait à sa fermeture
            var psi = new ProcessStartInfo("cmd.exe", "/d /c \"\"" + node + "\" src\\index.ts" + extra + " > \"" + log + "\" 2>&1\"")
            {
                WorkingDirectory = Path.Combine(dir, "service"),
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            try { Process.Start(psi); }
            catch (Exception e) { Fail("Could not start the service:\n" + e.Message); }
            // jusqu'à ~15 s (premier lancement : antivirus, pare-feu)
            for (int i = 0; i < 60 && !ServiceUp(); i++) Thread.Sleep(250);
            if (!ServiceUp()) Fail("The service did not start.\nSee " + log);
        }
        if (browser) Process.Start(new ProcessStartInfo(Url) { UseShellExecute = true });
    }
}
