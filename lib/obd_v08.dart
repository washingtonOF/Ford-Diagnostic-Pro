/// Leitura OBD-II genérica. Não acessa parâmetros proprietários do TCM Ford.
class DiagnosticCode {
  final String code;
  final String status;
  final String description;
  const DiagnosticCode(this.code, this.status, this.description);
  String get googleUrl => Uri.https('www.google.com', '/search', {
    'q': '$code Ford New Fiesta PowerShift significado diagnostico'
  }).toString();
}
const dtcDescriptionsPt = <String, String>{
  'P0805': 'Falha no circuito do sensor de posição da embreagem',
  'P2872': 'Embreagem A presa na posição engatada',
  'P0219': 'Condição de rotação excessiva do motor',
  'P0232': 'Sinal alto no circuito secundário da bomba de combustível',
  'P2610': 'Desempenho do temporizador interno de desligamento do módulo do motor',
  'P0043': 'Circuito de controle do aquecedor da sonda de oxigênio com sinal baixo (banco 1, sensor 3)',
};
String descriptionForDtc(String code) =>
    dtcDescriptionsPt[code] ?? 'Descrição não cadastrada. Consulte a documentação técnica.';

/// Aceita quadros com bytes separados ou compactos, sem inferir módulos Ford.
/// O parser não substitui uma implementação ISO-TP completa.
List<DiagnosticCode> parseDtcResponse(String raw, String mode) {
  final service = {'03': 0x43, '07': 0x47, '0A': 0x4A}[mode];
  if (service == null) throw ArgumentError.value(mode, 'mode');
  final status = {'03': 'Confirmado', '07': 'Pendente', '0A': 'Permanente'}[mode]!;
  final found = <String>{};
  for (var line in raw.toUpperCase().split(RegExp(r'[\r\n>]+'))) {
    line = line.trim();
    if (line.isEmpty || line.contains('NO DATA') || line.contains('SEARCHING') ||
        line.contains('STOPPED') || line.contains('ERROR') || line == '?') continue;
    final tokens = line.split(RegExp(r'\s+'));
    final bytes = <int>[];
    if (tokens.length == 1 && RegExp(r'^[0-9A-F]+$').hasMatch(tokens.first) &&
        tokens.first.length.isEven) {
      final hex = tokens.first;
      for (var i = 0; i < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
    } else {
      for (final token in tokens) {
        if (RegExp(r'^[0-9A-F]{2}$').hasMatch(token)) {
          bytes.add(int.parse(token, radix: 16));
        }
      }
    }
    final start = bytes.indexOf(service);
    if (start < 0) continue;
    for (var i = start + 1; i + 1 < bytes.length; i += 2) {
      final word = bytes[i] * 256 + bytes[i + 1];
      if (word == 0) continue;
      final prefix = 'PCBU'[(word >> 14) & 3];
      final digit = (word >> 12) & 3;
      final suffix = (word & 0x0FFF).toRadixString(16).toUpperCase().padLeft(3, '0');
      found.add('$prefix$digit$suffix');
    }
  }
  return found.map((code) => DiagnosticCode(code, status, descriptionForDtc(code))).toList();
}
double? fuelLevelPercent(String raw) {
  final match = RegExp(r'41\s*2F\s*([0-9A-F]{2})', caseSensitive: false).firstMatch(raw);
  if (match == null) return null;
  return int.parse(match.group(1)!, radix: 16) * 100 / 255;
}
double? mafGramsPerSecond(String raw) {
  final match = RegExp(r'41\s*10\s*([0-9A-F]{2})\s*([0-9A-F]{2})', caseSensitive: false).firstMatch(raw);
  if (match == null) return null;
  final a = int.parse(match.group(1)!, radix: 16);
  final b = int.parse(match.group(2)!, radix: 16);
  return (a * 256 + b) / 100;
}
/// Aproximação para gasolina: AFR estequiométrica 14,7; densidade 745 g/L.
/// Não é válida para etanol puro ou condições não estequiométricas.
double? fuelLitersPerHourFromMaf(double? maf) =>
    maf == null || maf < 0 ? null : maf * 3600 / (14.7 * 745);
double? instantaneousKmPerLiter(double? speedKmh, double? litersPerHour) =>
    speedKmh == null || litersPerHour == null || litersPerHour <= 0
      ? null : speedKmh / litersPerHour;
