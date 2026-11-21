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

/// Extrai bytes de respostas ELM327 sem confundir eco, cabeçalho CAN
/// ou índice de linha com dados. Quadros ISO-TP segmentados não são
/// reconstruídos aqui; não interpreta payloads incompletos.
List<int> _elmBytes(String rawLine) {
  var line = rawLine.trim().toUpperCase();
  if (line.isEmpty || line.contains('NO DATA') || line.contains('SEARCHING') ||
      line.contains('STOPPED') || line.contains('ERROR') || line == '?') return [];
  line = line.replaceFirst(RegExp(r'^\d+:\s*'), '');
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length > 1 && RegExp(r'^[0-9A-F]{3}$|^[0-9A-F]{8}$').hasMatch(parts.first)) {
    parts.removeAt(0); // CAN header, e.g. 7E8 or 18DAF110
  }
  final hex = parts.join();
  if (hex.isEmpty || hex.length.isOdd || !RegExp(r'^[0-9A-F]+$').hasMatch(hex)) return [];
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  // CAN ISO-TP single frame: 04 43 01 33 00
  if (bytes.length > 2 && bytes[0] <= 7 && bytes[1] >= 0x40 && bytes[1] <= 0x4F) {
    final length = bytes[0];
    if (length == 0 || length > bytes.length - 1) return [];
    return bytes.sublist(1, length + 1);
  }
  return bytes;
}

Iterable<List<int>> _responseFrames(String raw) sync* {
  for (final line in raw.split(RegExp(r'[\r\n>]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.toUpperCase() == 'SEARCHING...') continue;
    if (RegExp(r'^\d+\s*:').hasMatch(trimmed)) {
      throw const FormatException('Resposta OBD-II segmentada.');
    }
    final bytes = _elmBytes(trimmed);
    if (bytes.isEmpty) {
      throw FormatException('Resposta OBD-II inválida: $trimmed');
    }
    yield bytes;
  }
}

List<DiagnosticCode> parseDtcResponse(String raw, String mode) {
  final service = {'03': 0x43, '07': 0x47, '0A': 0x4A}[mode];
  if (service == null) throw ArgumentError.value(mode, 'mode');
  final status = {'03': 'Confirmado', '07': 'Pendente', '0A': 'Permanente'}[mode]!;
  final found = <String>{};
  var received = false;
  for (final bytes in _responseFrames(raw)) {
    if (bytes.first == int.parse(mode, radix: 16) && bytes.length == 1) continue;
    if (bytes.first != service || bytes.length < 2) {
      throw const FormatException('Resposta de falhas incompleta ou não reconhecida.');
    }
    received = true;
    final payload = bytes.sublist(1);
    // CAN inclui a contagem; protocolos legados retornam pares de bytes.
    final hasCount = payload.length.isOdd;
    final start = hasCount ? 1 : 0;
    final limit = hasCount ? 1 + 2 * payload.first : payload.length;
    if (limit > payload.length || payload.skip(limit).any((byte) => byte != 0)) {
      throw const FormatException('Quantidade de falhas incompatível com a resposta.');
    }
    for (var i = start; i < limit; i += 2) {
      final word = payload[i] * 256 + payload[i + 1];
      if (word == 0) continue;
      final prefix = 'PCBU'[(word >> 14) & 3];
      final digit = (word >> 12) & 3;
      final suffix = (word & 0x0FFF).toRadixString(16).toUpperCase().padLeft(3, '0');
      found.add('$prefix$digit$suffix');
    }
  }
  if (!received) throw const FormatException('Nenhuma resposta válida de falhas.');
  return found.map((code) => DiagnosticCode(code, status, descriptionForDtc(code))).toList();
}

bool confirmsDtcClear(String raw) {
  try {
    var confirmed = false;
    for (final bytes in _responseFrames(raw)) {
      if (bytes.length == 1 && bytes.first == 0x04) continue;
      if (bytes.first != 0x44 || bytes.skip(1).any((byte) => byte != 0)) return false;
      confirmed = true;
    }
    return confirmed;
  } on FormatException {
    return false;
  }
}

List<int>? parsePidBytes(String raw, int pid, int length) {
  try {
    List<int>? result;
    for (final bytes in _responseFrames(raw)) {
      if (bytes.length == 2 && bytes[0] == 0x01 && bytes[1] == pid) continue;
      if (bytes.length < length + 2 || bytes[0] != 0x41 || bytes[1] != pid) return null;
      final data = bytes.sublist(2, 2 + length);
      if (result != null && result.join(",") != data.join(",")) {
        return null;
      }
      result = data;
    }
    return result;
  } on FormatException {
    return null;
  }
}

double? fuelLevelPercent(String raw) {
  final data = parsePidBytes(raw, 0x2F, 1);
  return data == null ? null : data[0] * 100 / 255;
}
double? mafGramsPerSecond(String raw) {
  final data = parsePidBytes(raw, 0x10, 2);
  return data == null ? null : (data[0] * 256 + data[1]) / 100;
}
/// Aproximação para gasolina: AFR estequiométrica 14,7; densidade 745 g/L.
/// Não é válida para etanol puro ou condições não estequiométricas.
double? fuelLitersPerHourFromMaf(double? maf) =>
    maf == null || maf < 0 ? null : maf * 3600 / (14.7 * 745);
double? instantaneousKmPerLiter(double? speedKmh, double? litersPerHour) =>
    speedKmh == null || litersPerHour == null || litersPerHour <= 0
      ? null : speedKmh / litersPerHour;

enum FuelType { gasoline, ethanol }

/// Estimativa por MAF. AFR/densidade são valores de referência,
/// não medição de vazão de combustível. Misturas flex exigem calibração.
double? fuelLitersPerHour(double? maf, FuelType type) {
  if (maf == null || maf < 0) return null;
  final afr = type == FuelType.gasoline ? 14.7 : 9.0;
  final densityGramsPerLiter = type == FuelType.gasoline ? 745.0 : 789.0;
  return maf * 3600 / (afr * densityGramsPerLiter);
}
