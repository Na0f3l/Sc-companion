' Lance SC Companion sans fenetre de console :
'   - demarre le service Node en arriere-plan (cache), sauf s'il tourne deja ;
'   - attend qu'il reponde, puis ouvre l'interface dans le navigateur.
' Les messages du service vont dans service\service.log (ecrase a chaque lancement).
Option Explicit

Const PORT = 2950
Dim fso, sh, dir, url, i
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
  ' cmd /c pour rediriger la sortie vers le journal ; 0 = fenetre cachee, False = ne pas attendre
  sh.CurrentDirectory = dir & "\service"
  sh.Run "cmd /c node src\index.ts > service.log 2>&1", 0, False
  ' Attend jusqu'a ~10 s que le service soit pret
  For i = 1 To 40
    WScript.Sleep 250
    If ServiceUp() Then Exit For
  Next
  If Not ServiceUp() Then
    MsgBox "The service did not start." & vbCrLf & "See service\service.log", vbCritical, "SC Companion"
    WScript.Quit 1
  End If
End If

sh.Run url
