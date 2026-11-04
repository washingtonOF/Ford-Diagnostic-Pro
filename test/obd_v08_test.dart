import 'package:flutter_test/flutter_test.dart';
import 'package:ford_diagnostic_pro/obd_v08.dart';

void main() {
  test('DTC confirmado', () {
    final codes = parseDtcResponse('43 08 05 28 72 00 00', '03');
    expect(codes.map((c) => c.code), containsAll(['P0805', 'P2872']));
    expect(codes.first.status, 'Confirmado');
  });
  test('DTC com header CAN e frame curto', () {
    expect(parseDtcResponse('7E8 04 43 08 05 00', '03').first.code, 'P0805');
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
    expect(parseDtcResponse('NO DATA', '03'), isEmpty);
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
}
