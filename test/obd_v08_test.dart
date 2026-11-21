import 'package:flutter_test/flutter_test.dart';
import 'package:ford_diagnostic_pro/obd_v08.dart';
import 'package:ford_diagnostic_pro/trip_totals.dart';

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
  test('Decodifica as leituras do catalisador, sonda e combustível', () {
    expect(describeLiveReading('3C', '413C1377'), '458.3 °C');
    expect(describeLiveReading('14', '41148883'), '0.680 V • Ajuste curto: 2.34 %');
    expect(describeLiveReading('15', '41153EFF'), '0.310 V • Ajuste curto: indisponível');
    expect(describeLiveReading('51', '415103'), 'Etanol');
    expect(describeLiveReading('52', '4152D1'), '81.96 %');
    expect(describeLiveReading('1C', '411C14'), 'OBDBr-2');
  });
  test('Distingue prontidão concluída, pendente e não disponível', () {
    final report = describeLiveReading('01', '410181370101')!;
    expect(report, contains('Luz de injeção: acesa • Códigos: 1'));
    expect(report, contains('Catalisador: Não concluído'));
    expect(report, contains('Catalisador aquecido: Não disponível'));
    expect(report, contains('Componentes: Concluído'));
    expect(describeLiveReading('41', '414100070100'), contains('Catalisador: Concluído'));
    expect(describeLiveReading('A4', '41A4020005DC'), '1.500');
  });
  test('Estatísticas calculam custo e consumo só quando há dados', () {
    final movement = TripTotals.sample(360, 50, 5, 6);
    final stopped = TripTotals.sample(360, 0, 1, 6);
    final blind = TripTotals.sample(360, 50, null, null);
    final total = TripTotals.fromJson((movement + stopped + blind).toJson());
    expect(total.distance, 10);
    expect(total.averageSpeed, closeTo(100 / 3, 0.001));
    expect(total.consumption, closeTo(12, 0.001));
    expect(total.fuelCost, closeTo(3.6, 0.001));
    expect(total.stoppedSeconds, 360);
    expect((total + TripTotals.sample(360, 20, 2, null)).fuelCost, isNull);
    expect(blind.consumption, isNull);
  });
}
