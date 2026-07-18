/// Office document classification & detection utilities.
library;

enum OfficeApp { word, excel, powerpoint }

const _officeExtMap = <String, OfficeApp>{
  'doc': OfficeApp.word, 'docx': OfficeApp.word, 'odt': OfficeApp.word,
  'xls': OfficeApp.excel, 'xlsx': OfficeApp.excel, 'ods': OfficeApp.excel,
  'ppt': OfficeApp.powerpoint, 'pptx': OfficeApp.powerpoint, 'odp': OfficeApp.powerpoint,
};

bool isOfficeDocument(String filePath) {
  final ext = filePath.split('.').last.toLowerCase();
  return _officeExtMap.containsKey(ext);
}

OfficeApp? officeAppFor(String filePath) {
  final ext = filePath.split('.').last.toLowerCase();
  return _officeExtMap[ext];
}

String officeAppLabel(OfficeApp app) {
  switch (app) {
    case OfficeApp.word: return 'Microsoft Word';
    case OfficeApp.excel: return 'Microsoft Excel';
    case OfficeApp.powerpoint: return 'Microsoft PowerPoint';
  }
}

/// Build a PowerShell script as a plain string.
/// $args[0] = input, $args[1] = output, $args[2] = page range
String buildPowershellScript(OfficeApp app, String inputPath, String outputPath, String pageRange) {
  final inp = inputPath.replaceAll('\\', '\\\\');
  final out = outputPath.replaceAll('\\', '\\\\');

  String body;
  switch (app) {
    case OfficeApp.word:
      body = _wordBody(inp, out, pageRange);
      break;
    case OfficeApp.excel:
      body = _excelBody(inp, out, pageRange);
      break;
    case OfficeApp.powerpoint:
      body = _pptBody(inp, out, pageRange);
      break;
  }
  return '\$ErrorActionPreference = "Stop"\n'
      '\$inp = "$inp"\n'
      '\$out = "$out"\n'
      '\$pages = "$pageRange"\n$body';
}

String _wordBody(String inp, String out, String pages) {
  return _pageRangePs +
      'try {\$w=New-Object -ComObject Word.Application;\$w.Visible=\$false;'
      '\$d=\$w.Documents.Open(\$inp,\$false,\$true);'
      '\$d.ExportAsFixedFormat(\$out,17,\$false,0,\$range,\$from,\$to,0,\$true,\$true,1,\$true);'
      '\$d.Close(0);\$w.Quit();Write-Output "OK"}'
      'catch{Write-Error \$_.Exception.Message;if(\$w){\$w.Quit()};exit 1}';
}

String _excelBody(String inp, String out, String pages) {
  return _pageRangePs +
      'try {\$e=New-Object -ComObject Excel.Application;\$e.Visible=\$false;\$e.DisplayAlerts=\$false;'
      '\$wb=\$e.Workbooks.Open(\$inp,0,\$true);'
      'if(\$range -eq 3){\$wb.ExportAsFixedFormat(0,\$out,0,\$false,\$false,\$from,\$to)}else{\$wb.ExportAsFixedFormat(0,\$out)}'
      '\$wb.Close(\$false);\$e.Quit();Write-Output "OK"}'
      'catch{Write-Error \$_.Exception.Message;if(\$e){\$e.Quit()};exit 1}';
}

String _pptBody(String inp, String out, String pages) {
  return _pageRangePs +
      'try {\$p=New-Object -ComObject PowerPoint.Application;'
      '\$pres=\$p.Presentations.Open(\$inp,\$true,\$false,\$false);'
      'if(\$range -eq 3){\$pres.ExportAsFixedFormat(\$out,2,0,\$false,0,\$from,\$to,\$false)}else{\$pres.SaveAs(\$out,32)}'
      '\$pres.Close();\$p.Quit();Write-Output "OK"}'
      'catch{Write-Error \$_.Exception.Message;if(\$p){\$p.Quit()};exit 1}';
}

const _pageRangePs =
    '\$range=0;\$from=1;\$to=1;'
    'if(\$pages -ne "all" -and \$pages -ne ""){'
    'if(\$pages -match "^\\s*(\\d+)\\s*-\\s*(\\d+)\\s*\$"){\$range=3;\$from=[int]\$Matches[1];\$to=[int]\$Matches[2]}'
    'elseif(\$pages -match "^\\s*(\\d+)\\s*\$"){\$range=3;\$from=[int]\$Matches[1];\$to=\$from}}';
