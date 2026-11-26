' Lance SC Companion sans fenetre de console :
'   - demarre le service Node en arriere-plan (cache), sauf s'il tourne deja ;
'   - attend qu'il reponde, puis ouvre l'interface dans le navigateur.
' Node : celui livre avec l'appli (node\node.exe, version publiee), sinon celui installe sur le PC (developpement).
' Les messages du service vont dans %LOCALAPPDATA%\SC Companion\service.log (ecrase a chaque lancement) :
' le dossier de l'appli peut etre en lecture seule (Program Files).
Option Explicit

Const PORT = 2950
Dim fso, sh, dir, url, i, node, data, logFile
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
url = "http://localhost:" & PORT

' Le service repond-il deja ? (requete courte sur /health)
Function ServiceUp()
  Dim http
  ServiceUp = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 500, 500, 500, 500
  http.open "GET", url & "/health", False
  http.send
  If Err.Number = 0 Then ServiceUp = (http.status = 200)
  On Error GoTo 0
End Function

If Not ServiceUp() Then
  If Not fso.FileExists(dir & "\interface\dist\index.html") Then
    MsgBox "Interface not built." & vbCrLf & "Run 'npm run build' in the interface folder first.", vbExclamation, "SC Companion"
    WScript.Quit 1
  End If
  node = "node"
  If fso.FileExists(dir & "\node\node.exe") Then node = """" & dir & "\node\node.exe"""
  data = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\SC Companion"
  If Not fso.FolderExists(data) Then fso.CreateFolder data
  logFile = data & "\service.log"
  ' cmd /c pour rediriger la sortie vers le journal ; 0 = fenetre cachee, False = ne pas attendre
  sh.CurrentDirectory = dir & "\service"
  sh.Run "cmd /c """ & node & " src\index.ts > """ & logFile & """ 2>&1""", 0, False
  ' Attend jusqu'a ~15 s que le service soit pret (premier lancement : antivirus, pare-feu)
  For i = 1 To 60
    WScript.Sleep 250
    If ServiceUp() Then Exit For
  Next
  If Not ServiceUp() Then
    MsgBox "The service did not start." & vbCrLf & "See " & logFile, vbCritical, "SC Companion"
    WScript.Quit 1
  End If
End If

sh.Run url
