import 'package:flutter_test/flutter_test.dart';
import 'package:ford_diagnostic_pro/obd_v08.dart';

void main() {
  test('DTC confirmado', () {
    final codes = parseDtcResponse('43 08 05 28 72 00 00', '03');
    expect(codes.map((c) => c.code), containsAll(['P0805', 'P2872']));
    expect(codes.first.status, 'Confirmado');
  });
  test('DTC com header CAN e frame curto', () {
    expect(parseDtcResponse('7E8 04 43 01 08 05', '03').first.code, 'P0805');
  });
  test('DTC compacto sem espacos', () {
    expect(parseDtcResponse('4308050000', '03').first.code, 'P0805');
  });
  test('PID compactos e CAN', () {
    expect(fuelLevelPercent('412FFF'), closeTo(100, 0.001));
    expect(mafGramsPerSecond('7E8 04 41 10 01 F4'), 5);
  });
  test('DTC pendente e permanente', () {
    expect(parseDtcResponse('47 08 05', '07').first.status, 'Pendente');
    expect(parseDtcResponse('4A 08 05', '0A').first.status, 'Permanente');
  });
  test('Sem dados não inventa códigos', () {
    expect(() => parseDtcResponse('NO DATA', '03'), throwsFormatException);
  });
  test('Nível combustível', () {
    expect(fuelLevelPercent('41 2F FF'), closeTo(100, 0.001));
  });
  test('Seleção de combustível altera estimativa', () {
    final gas = fuelLitersPerHour(10, FuelType.gasoline)!;
    final ethanol = fuelLitersPerHour(10, FuelType.ethanol)!;
    expect(ethanol, greaterThan(gas));
  });
  test('Dados ausentes não produzem estimativas', () {
    expect(fuelLitersPerHour(null, FuelType.gasoline), isNull);
    expect(instantaneousKmPerLiter(0, null), isNull);
  });
  test('MAF e consumo', () {
    expect(mafGramsPerSecond('41 10 01 F4'), 5);
    expect(fuelLitersPerHourFromMaf(5), greaterThan(0));
    expect(instantaneousKmPerLiter(60, 5), 12);
  });
  test('TCM: lê falhas UDS em múltiplos quadros e ignora outros módulos', () {
    final codes = parseFordDtcResponse(
      '7E8 03 59 02 FF\r7E9 10 0B 59 02 FF 08 05 11\r7E9 21 09 28 72 00 04 00 00',
      '7E9', 'TCM PowerShift',
    );
    expect(codes.map((code) => code.code), ['P0805:11', 'P2872:00']);
    expect(codes.first.status, contains('Confirmado'));
    expect(codes.last.status, contains('Pendente'));
  });
  test('PCM: uma resposta válida vazia é distinta de falha de comunicação', () {
    expect(parseFordDtcResponse('7E8 03 59 02 FF', '7E8', 'PCM Motor'), isEmpty);
    expect(() => parseFordDtcResponse('NO DATA', '7E8', 'PCM Motor'), throwsStateError);
    expect(() => parseFordDtcResponse('7E8 03 7F 19 11', '7E8', 'PCM Motor'), throwsStateError);
  });
  test('TCM: descarta respostas com sequência incompleta', () {
    expect(
      () => parseFordDtcResponse('7E9 10 0B 59 02 FF 08 05 11\r7E9 22 09 28 72 00 04', '7E9', 'TCM'),
      throwsFormatException,
    );
  });
}
