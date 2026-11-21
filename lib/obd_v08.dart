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

String obdHex(int value) => value.toRadixString(16).toUpperCase().padLeft(2, '0');

List<String> decodeSupportedIds(String response, int mode, int base) {
  final ids = <String>{};
  for (final line in response.split(RegExp(r'[\r\n>]+'))) {
    final bytes = _elmBytes(line);
    final offset = mode == 2 ? 3 : 2;
    if (bytes.length < offset + 4 || bytes[0] != 0x40 + mode || bytes[1] != base ||
        (mode == 2 && bytes[2] != 0)) continue;
    for (var bit = 0; bit < 32 && base + bit + 1 <= 255; bit++) {
      if ((bytes[offset + bit ~/ 8] & (0x80 >> (bit % 8))) != 0) {
        ids.add(obdHex(base + bit + 1));
      }
    }
  }
  return ids.toList()..sort();
}

const obdReadingNames = <String, String>{
  '04': 'Carga calculada', '05': 'Temperatura do líquido de arrefecimento',
  '06': 'Correção de combustível de curto prazo (banco 1)',
  '07': 'Correção de combustível de longo prazo (banco 1)',
  '08': 'Correção de combustível de curto prazo (banco 2)',
  '09': 'Correção de combustível de longo prazo (banco 2)',
  '0A': 'Pressão de combustível', '0B': 'Pressão absoluta do coletor',
  '0C': 'Rotação do motor', '0D': 'Velocidade do veículo',
  '0E': 'Avanço de ignição', '0F': 'Temperatura do ar de admissão',
  '10': 'Fluxo de ar (MAF)', '11': 'Posição da borboleta',
  '1F': 'Tempo desde a partida', '21': 'Distância com luz de falha acesa',
  '2C': 'EGR comandada', '2E': 'Purga evaporativa comandada',
  '2F': 'Nível de combustível', '30': 'Aquecimentos desde a limpeza',
  '31': 'Distância desde a limpeza', '33': 'Pressão barométrica',
  '42': 'Tensão do módulo', '45': 'Posição relativa da borboleta',
  '46': 'Temperatura ambiente', '5C': 'Temperatura do óleo',
  '5E': 'Vazão de combustível',
};

String? describeLiveReading(String pid, String raw) {
  if (!obdReadingNames.containsKey(pid)) return null;
  final length = {'0C', '10', '1F', '21', '31', '42', '5E'}.contains(pid) ? 2 : 1;
  final data = parsePidBytes(raw, int.parse(pid, radix: 16), length);
  if (data == null) return null;
  final a = data.first;
  final word = length == 2 ? a * 256 + data[1] : a;
  return switch (pid) {
    '04' || '11' || '2C' || '2E' || '2F' || '45' => '${(a * 100 / 255).toStringAsFixed(1)} %',
    '05' || '0F' || '46' || '5C' => '${a - 40} °C',
    '06' || '07' || '08' || '09' => '${((a - 128) * 100 / 128).toStringAsFixed(1)} %',
    '0A' => '${a * 3} kPa',
    '0B' || '33' => '$a kPa',
    '0C' => '${word / 4} rpm',
    '0D' => '$a km/h',
    '0E' => '${a / 2 - 64} °',
    '10' => '${(word / 100).toStringAsFixed(2)} g/s',
    '1F' => '$word s',
    '21' || '31' => '$word km',
    '30' => '$a ciclos',
    '42' => '${(word / 1000).toStringAsFixed(2)} V',
    '5E' => '${(word / 20).toStringAsFixed(2)} L/h',
    _ => null,
  };
}

List<DiagnosticCode> parseFordDtcResponse(String raw, String responseId, String module) {
  final payload = <int>[];
  int? expectedLength;
  var nextSequence = 1;
  var complete = false;

  for (final line in raw.toUpperCase().split(RegExp(r'[\r\n>]+'))) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (!compact.startsWith(responseId)) continue;
    final hex = compact.substring(responseId.length);
    if (hex.length < 4 || hex.length.isOdd || !RegExp(r'^[0-9A-F]+$').hasMatch(hex)) {
      throw const FormatException('Quadro CAN inválido.');
    }
    final bytes = [
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    final type = bytes.first >> 4;
    if (type == 0) {
      final length = bytes.first & 0x0F;
      if (expectedLength != null || length == 0 || length > 7 || length >= bytes.length) {
        throw const FormatException('Tamanho inválido na resposta CAN.');
      }
      final frame = bytes.sublist(1, length + 1);
      // Resposta pendente. A central ainda pode enviar a resposta final no mesmo comando.
      if (frame.length == 3 && frame[0] == 0x7F && frame[1] == 0x19 && frame[2] == 0x78) continue;
      payload.addAll(frame);
      complete = true;
      break;
    }
    if (type == 1 && expectedLength == null) {
      expectedLength = ((bytes.first & 0x0F) << 8) | bytes[1];
      if (expectedLength <= 7 || bytes.length < 3) {
        throw const FormatException('Início de mensagem ISO-TP inválido.');
      }
      payload.addAll(bytes.skip(2));
    } else if (type == 2 && expectedLength != null && (bytes.first & 0x0F) == nextSequence) {
      payload.addAll(bytes.skip(1));
      nextSequence = (nextSequence + 1) & 0x0F;
    } else {
      throw const FormatException('Sequência ISO-TP inválida.');
    }
    if (payload.length >= expectedLength) {
      payload.removeRange(expectedLength, payload.length);
      complete = true;
      break;
    }
  }

  if (!complete) {
    if (expectedLength == null && raw.trim().toUpperCase().contains('NO DATA')) {
      throw StateError('Sem resposta do módulo.');
    }
    throw const FormatException('Resposta do módulo ausente ou incompleta.');
  }
  if (payload.length >= 3 && payload[0] == 0x7F && payload[1] == 0x19) {
    throw StateError('Módulo respondeu, mas recusou a leitura (NRC ${obdHex(payload[2])}).');
  }
  if (payload.length < 3 || payload[0] != 0x59 || payload[1] != 0x02 ||
      (payload.length - 3) % 4 != 0) {
    throw const FormatException('Resposta de falhas UDS inválida.');
  }

  return [
    for (var i = 3; i < payload.length; i += 4)
      _fordDiagnosticCode(payload[i], payload[i + 1], payload[i + 2], payload[i + 3], module),
  ];
}

DiagnosticCode _fordDiagnosticCode(int high, int low, int subtype, int status, String module) {
  final code = '${'PCBU'[high >> 6]}${(high >> 4) & 3}${obdHex(high & 15)[1]}${obdHex(low)}';
  final flags = [
    if ((status & 0x01) != 0) 'Falha presente',
    if ((status & 0x08) != 0) 'Confirmado',
    if ((status & 0x04) != 0) 'Pendente',
    'Status 0x${obdHex(status)}',
  ];
  return DiagnosticCode('$code:${obdHex(subtype)}', '$module • ${flags.join(' • ')}', descriptionForDtc(code));
}
