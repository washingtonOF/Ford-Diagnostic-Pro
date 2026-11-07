import 'dart:async';
import 'obd_v08.dart' as v08;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const FordApp());

class ObdService {
  static const _channel = MethodChannel('ford_diagnostic/obd');
  Future<List<Map<String, String>>> paired() async {
    final result = await _channel.invokeMethod<List<dynamic>>('paired');
    return (result ?? []).map((e) => Map<String, String>.from(e as Map)).toList();
  }
  Future<void> connect(String address) => _channel.invokeMethod('connect', {'address': address});
  Future<void> disconnect() => _channel.invokeMethod('disconnect');
  Future<String> command(String cmd) async =>
      (await _channel.invokeMethod<String>('command', {'command': cmd})
          .timeout(const Duration(seconds: 12))) ?? '';
  Future<void> initialize() async {
    for (final cmd in ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']) {
      final response = (await command(cmd)).toUpperCase();
      if (response.contains('?') || response.contains('ERROR')) {
        throw StateError('ELM327 rejeitou $cmd: $response');
      }
    }
    final response = (await command('0100')).toUpperCase();
    if (!response.contains('41')) {
      throw StateError('ELM327 respondeu, mas o veículo não retornou dados OBD-II: $response');
    }
  }
}

String? obdData(String response, String service, String pid) {
  final cleaned = response.toUpperCase().split(RegExp(r'[\r\n]')).where((line) => !line.contains('SEARCHING') && !line.contains('NO DATA') && !line.contains('STOPPED') && !line.contains('ERROR')).join().replaceAll(RegExp(r'[^0-9A-F]'), '');
  final marker = '$service$pid';
  final i = cleaned.indexOf(marker);
  if (i < 0) return null;
  return cleaned.substring(i + marker.length);
}

int? byteAt(String data, int offset) {
  if (data.length < offset + 2) return null;
  return int.tryParse(data.substring(offset, offset + 2), radix: 16);
}

String decodePid(String pid, String response) {
  final d = obdData(response, '41', pid);
  if (d == null) return 'Indisponível';
  final a = byteAt(d, 0);
  final b = byteAt(d, 2);
  if (a == null) return 'Indisponível';
  switch (pid) {
    case '05': return '${a - 40} °C';
    case '0C': return b == null ? 'Indisponível' : '${((a * 256 + b) / 4).round()} rpm';
    case '0D': return '$a km/h';
    case '0F': return '${a - 40} °C';
    case '04': return '${(a * 100 / 255).toStringAsFixed(1)} %';
    case '42': return b == null ? 'Indisponível' : '${((a * 256 + b) / 1000).toStringAsFixed(2)} V';
    default: return 'Indisponível';
  }
}

List<String> decodeDtc(String response) {
  final cleaned = response.toUpperCase().split(RegExp(r'[\r\n]')).where((line) => !line.contains('NO DATA') && !line.contains('ERROR')).join().replaceAll(RegExp(r'[^0-9A-F]'), '');
  final i = cleaned.indexOf('43');
  if (i < 0) return [];
  final payload = cleaned.substring(i + 2);
  final codes = <String>[];
  for (var j = 0; j + 4 <= payload.length; j += 4) {
    final n = int.tryParse(payload.substring(j, j + 4), radix: 16);
    if (n == null || n == 0) continue;
    final prefix = ['P', 'C', 'B', 'U'][(n >> 14) & 3];
    codes.add('$prefix${(n >> 12) & 3}${(n & 0x0FFF).toRadixString(16).toUpperCase().padLeft(3, '0')}');
  }
  return codes;
}

/// Inventário de módulos: catálogo de funções, NÃO uma alegação de acesso real.
/// A descoberta Ford específica requer implementação e validação de CAN/ISO-TP.
class FordModuleCapability {
  final String id, name, bus, notes;
  final bool activeTestsAllowed;
  const FordModuleCapability(this.id, this.name, this.bus, this.notes,
      {this.activeTestsAllowed = false});
}

const fordModules = <FordModuleCapability>[
  FordModuleCapability('PCM', 'Motor e injeção', 'HS-CAN', 'OBD2 genérico disponível; funções Ford aprimoradas pendentes'),
  FordModuleCapability('TCM', 'Transmissão PowerShift DPS6', 'HS-CAN', 'DTCs, temperaturas, atuadores e adaptações exigem protocolo validado'),
  FordModuleCapability('ABS', 'Freios e estabilidade', 'HS-CAN', 'Leitura de falhas aprimorada ainda não implementada'),
  FordModuleCapability('PSCM', 'Direção elétrica', 'HS-CAN', 'Acesso aprimorado ainda não implementado'),
  FordModuleCapability('BCM', 'Módulo de carroceria', 'MS-CAN/varia', 'Pode exigir hardware com comutação HS/MS-CAN'),
  FordModuleCapability('IPC', 'Painel de instrumentos', 'MS-CAN/varia', 'Disponibilidade depende da arquitetura do veículo'),
  FordModuleCapability('RCM', 'Airbag e retenção', 'HS-CAN/varia', 'Nenhum teste ativo permitido'),
];

class FordApp extends StatelessWidget {
  const FordApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ford Diagnostic Pro', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xFF4BA3FF), scaffoldBackgroundColor: const Color(0xFF101A2A)),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final obd = ObdService();
  List<Map<String, String>> devices = [];
  final values = <String, String>{};
  final history = <String>[];
  final supported = <String>{};
  String adapterInfo = 'Não identificado';
  String protocolInfo = 'Não identificado';
  String vin = 'Não consultado';
  bool discovering = false;
  final sessionReadings = <String>[];
  final List<double> speedSamples = [];
  final List<double> temperatureSamples = [];
  DateTime? lastTripSample;
  double tripKm = 0;
  double estimatedLiters = 0;
  double? fuelPercent;
  double? currentLph;
  double? currentKml;
  v08.FuelType fuelType = v08.FuelType.gasoline;
  List<String> codes = [];
  final List<v08.DiagnosticCode> allCodes = [];
  final Map<String, String> codeStatuses = {};
  int selectedTab = 0;
  bool editingPanel = false;
  bool showVehicleBanner = true;
  bool compactSensors = false;
  final List<String> sensorOrder = ['05', '0C', '42', '0D', '0F', '04'];
  final Set<String> hiddenSensors = <String>{};
  bool connected = false, busy = false;
  bool connectingBluetooth = false;
  bool readingDiagnosticCodes = false;
  String diagnosticProgress = '';
  String status = 'Desconectado';
  Timer? timer;
  final pids = const {'05':'Temperatura motor', '0C':'Rotação', '0D':'Velocidade',
    '42':'Tensão módulo', '0F':'Temperatura admissão', '04':'Carga calculada'};

  @override
  void initState() {
    super.initState();
    loadHistory();
    loadPanelPreferences();
    loadLayoutPreferences();
  }

  Future<void> loadLayoutPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      showVehicleBanner = prefs.getBool('show_vehicle_banner_v07') ?? true;
      compactSensors = prefs.getBool('compact_sensors_v07') ?? false;
    });
  }

  Future<void> updateLayout({bool? banner, bool? compact}) async {
    setState(() {
      if (banner != null) showVehicleBanner = banner;
      if (compact != null) compactSensors = compact;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_vehicle_banner_v07', showVehicleBanner);
    await prefs.setBool('compact_sensors_v07', compactSensors);
  }

  Future<void> loadPanelPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('panel_sensor_order_v06') ?? [];
    final known = sensorOrder.toSet();
    final ordered = <String>[
      ...saved.where(known.contains).toSet(),
      ...sensorOrder.where((pid) => !saved.contains(pid)),
    ];
    final hidden = (prefs.getStringList('panel_hidden_sensors_v06') ?? [])
        .where(known.contains).toSet();
    if (!mounted) return;
    setState(() {
      sensorOrder..clear()..addAll(ordered);
      hiddenSensors..clear()..addAll(hidden);
    });
  }

  Future<void> savePanelPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('panel_sensor_order_v06', sensorOrder);
    await prefs.setStringList('panel_hidden_sensors_v06', hiddenSensors.toList());
  }

  void moveSensor(int oldIndex, int newIndex) {
    setState(() {
      
      final item = sensorOrder.removeAt(oldIndex);
      sensorOrder.insert(newIndex, item);
    });
    savePanelPreferences();
  }

  void resetPanel() {
    setState(() {
      sensorOrder..clear()..addAll(['05', '0C', '42', '0D', '0F', '04']);
      hiddenSensors.clear();
    });
    savePanelPreferences();
  }

  Future<void> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => history.addAll(prefs.getStringList('diagnostic_history') ?? []));
  }

  Future<void> record(String event) async {
    final entry = '${DateTime.now().toIso8601String()} | $event';
    history.insert(0, entry);
    if (history.length > 1000) history.removeRange(1000, history.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('diagnostic_history', history);
    if (mounted) setState(() {});
  }

  Future<void> discover() async {
    if (!connected || polling || discovering) return;
    setState(() => discovering = true);
    try {
      adapterInfo = (await obd.command('ATI')).trim();
      protocolInfo = (await obd.command('ATDP')).trim();
      supported.clear();
      for (final base in [0, 32, 64, 96, 128, 160, 192, 224]) {
        final pid = base.toRadixString(16).padLeft(2, '0').toUpperCase();
        final data = obdData(await obd.command('01$pid'), '41', pid);
        if (data == null || data.length < 8) break;
        final mask = int.tryParse(data.substring(0, 8), radix: 16);
        if (mask == null) break;
        for (var i = 0; i < 32; i++) {
          if ((mask & (1 << (31 - i))) != 0) supported.add((base + i + 1).toRadixString(16).padLeft(2, '0').toUpperCase());
        }
        if ((mask & 1) == 0) break;
      }
      await record('Descoberta: ${supported.length} PIDs anunciados; adaptador $adapterInfo; protocolo $protocolInfo');
    } catch (e) { report(e); }
    finally { if (mounted) setState(() => discovering = false); }
  }

  Future<void> readVin() async {
    if (!connected || polling || busy || discovering) return;
    setState(() => busy = true);
    try {
      final raw = await obd.command('0902');
      // O VIN pode chegar fragmentado em quadros ISO-TP; preservar resposta para inspeção.
      vin = raw.trim();
      await record('Identificação veículo (resposta bruta modo 09): $vin');
    } catch (e) { report(e); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> readAdditionalCodes(String mode, String label) async {
    await readDiagnosticMode(mode, label);
  }

  /// Exclusividade da conexão: pausa o agendamento e aguarda o polling atual.
  Future<void> readDiagnosticMode(String mode, String label) async {
    if (!connected || busy || discovering) return;
    timer?.cancel();
    setState(() {
      busy = true;
      readingDiagnosticCodes = true;
      diagnosticProgress = 'Buscando $label...';
      status = 'Consultando $label...';
    });
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (polling && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (polling) throw StateError('Sensores ocupados; tente novamente.');
      if (mounted) setState(() => diagnosticProgress = 'Analisando respostas da central...');
      final response = await obd.command(mode);
      await record('Consulta $label (modo $mode) | bruto: ${response.trim()}');
      final upper = response.toUpperCase();
      if (upper.trim().isEmpty || upper.contains('ERROR') ||
          upper.contains('STOPPED') || upper.contains('UNABLE TO CONNECT') ||
          upper.contains('NO DATA') || upper.trim() == '?') {
        throw StateError('Resposta inválida para $label: ${response.trim()}');
      }
      final marker = {'03': '43', '07': '47', '0A': '4A'}[mode]!;
      if (!upper.replaceAll(RegExp(r'[^0-9A-F]'), '').contains(marker)) {
        throw StateError('Resposta não reconhecida para $label: ${response.trim()}');
      }
      final parsed = v08.parseDtcResponse(response, mode);
      final category = {'03': 'Confirmado', '07': 'Pendente', '0A': 'Permanente'}[mode]!;
      if (!mounted) return;
      setState(() {
        allCodes.removeWhere((e) => e.status == category);
        allCodes.addAll(parsed);
        if (mode == '03') {
          codes = parsed.map((e) => e.code).toList();
          for (final code in codes) { codeStatuses[code] = category; }
        }
        status = '$label: ${parsed.length} código(s) encontrado(s)';
      });
    } catch (e) { report(e); }
    finally {
      if (mounted) setState(() { busy = false; readingDiagnosticCodes = false; diagnosticProgress = ''; });
      if (connected) {
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
      }
    }
  }

  Future<void> scan() async {
    try {
      final found = await obd.paired();
      if (mounted) setState(() { devices = found; status = 'Selecione um adaptador pareado'; });
    } catch (e) { report(e); }
  }
  void report(Object e) {
    if (mounted) setState(() => status = 'Erro na comunicação: $e');
  }

  Future<void> exportPdf() async {
    try {
      final doc = pw.Document();
      final report = <String>[
        'Ford Diagnostic Pro V0.8 — Relatorio',
        'Gerado em: ' + DateTime.now().toIso8601String(),
        'Distancia estimada: ' + tripKm.toStringAsFixed(2) + ' km',
        'Combustivel estimado: ' + estimatedLiters.toStringAsFixed(2) + ' L',
        'DTCs: ' + allCodes.map((e) => e.code + ' (' + e.status + ')').join(', '),
        'Sensores: ' + values.toString(),
        'Leituras nao substituem diagnostico profissional.',
      ];
      doc.addPage(pw.MultiPage(build: (_) => [
        for (final line in report) pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Text(line)),
      ]));
      await Printing.sharePdf(bytes: await doc.save(), filename: 'ford_diagnostic_v08.pdf');
    } catch (e) { report(e); }
  }

  Future<void> copyHistory() async {
    if (history.isEmpty) return;
    await Clipboard.setData(ClipboardData(text:
      'Ford Diagnostic Pro V0.8 - histórico de diagnóstico\n'
      '${history.join('\n')}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Histórico copiado. Cole em um arquivo ou mensagem.')));
  }

  Future<void> connect(String address) async {
    if (busy) return;
    setState(() { busy = true; connectingBluetooth = true; status = 'Conectando ao ELM327...'; });
    try {
      await obd.connect(address).timeout(const Duration(seconds: 25));
      if (mounted) setState(() => status = 'Bluetooth conectado. Inicializando OBD-II...');
      await obd.initialize();
      if (!mounted) return;
      setState(() { connected = true; status = 'Conectado'; });
      timer?.cancel();
      setState(() => busy = false);
      await discover();
      await poll();
      timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    } catch (e) {
      report(e is TimeoutException
          ? StateError('Tempo esgotado ao conectar ao ELM327. Verifique pareamento e ignição.')
          : e);
      await obd.disconnect();
      if (mounted) setState(() => connected = false);
    }
    finally { if (mounted) setState(() { busy = false; connectingBluetooth = false; }); }
  }
  bool polling = false;
  Future<void> poll() async {
    if (!connected || polling || busy || discovering) return;
    polling = true;
    try {
      for (final pid in pids.keys.where((pid) => supported.contains(pid))) {
        final r = await obd.command('01$pid');
        if (mounted) setState(() => values[pid] = decodePid(pid, r));
      }
      final now = DateTime.now();
      final rawSpeed = values['0D'];
      final speed = rawSpeed == null ? null : double.tryParse(rawSpeed.replaceAll(' km/h', ''));
      final rawTemp = values['05'];
      final temp = rawTemp == null ? null : double.tryParse(rawTemp.replaceAll(' °C', ''));
      if (speed != null) {
        speedSamples.add(speed);
        if (speedSamples.length > 60) speedSamples.removeAt(0);
      }
      if (temp != null) {
        temperatureSamples.add(temp);
        if (temperatureSamples.length > 60) temperatureSamples.removeAt(0);
      }
      fuelPercent = supported.contains('2F')
          ? v08.fuelLevelPercent(await obd.command('012F')) : null;
      if (supported.contains('10')) {
        final maf = v08.mafGramsPerSecond(await obd.command('0110'));
        currentLph = v08.fuelLitersPerHour(maf, fuelType);
        currentKml = v08.instantaneousKmPerLiter(speed, currentLph);
      } else {
        currentLph = null;
        currentKml = null;
      }
      if (lastTripSample != null && speed != null) {
        final hours = now.difference(lastTripSample!).inMilliseconds / 3600000.0;
        if (hours > 0 && hours < 0.02) {
          tripKm += speed * hours;
          if (currentLph != null) estimatedLiters += currentLph! * hours;
        }
      }
      lastTripSample = now;
      if (mounted) setState(() {});
      if (values.isNotEmpty) sessionReadings.add('${DateTime.now().toIso8601String()} ${jsonEncode(values)}');
      if (sessionReadings.length >= 20) { await record('Amostras sensores: ${jsonEncode(sessionReadings)}'); sessionReadings.clear(); }
    } catch (e) { report(e); timer?.cancel(); if (mounted) setState(() => connected = false); }
    finally { polling = false; }
  }
  Future<void> readCodes() => readDiagnosticMode('03', 'Falhas confirmadas');
  Future<void> clearGenericCodes() async {
    if (!connected || busy || discovering) return;
    timer?.cancel();
    // Aguarda a leitura em andamento terminar antes de enviar comandos de escrita.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (polling) {
      report(StateError('Comunicação ocupada. Aguarde e tente novamente.'));
      if (connected) timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final rawSpeed = await obd.command('010D');
      final data = obdData(rawSpeed, '41', '0D');
      if (data == null || byteAt(data, 0) != 0) {
        throw StateError('Limpeza bloqueada: velocidade zero não confirmada.');
      }
      final rpmRaw = await obd.command('010C');
      final rpmData = obdData(rpmRaw, '41', '0C');
      final rpmA = rpmData == null ? null : byteAt(rpmData, 0);
      final rpmB = rpmData == null ? null : byteAt(rpmData, 2);
      if (rpmA == null || rpmB == null || rpmA * 256 + rpmB != 0) {
        throw StateError('Limpeza bloqueada: motor desligado não confirmado pelo RPM.');
      }
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Apagar falhas genéricas?'),
          content: const Text('O comando OBD-II 04 apaga falhas genéricas, dados congelados e monitores de prontidão. '
            'Não corrige defeitos nem garante limpar o TCM. Faça somente com veículo parado, '
            'ignição ligada e motor desligado quando indicado. Confirmar?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmar limpeza')),
          ],
        ),
      );
      if (approved != true) return;
      final response = (await obd.command('04')).toUpperCase();
      await record('Modo 04: ' + response);
      if (!RegExp(r'(^|[^0-9A-F])44([^0-9A-F]|$)').hasMatch(response) &&
          !RegExp(r'^44(?:00)*>?
      final reread = await obd.command('03');
      if (reread.trim().isEmpty || reread.toUpperCase().contains('ERROR') ||
          reread.toUpperCase().contains('NO DATA')) {
        throw StateError('Comando 04 confirmado, mas não foi possível verificar as falhas: $reread');
      }
      final remaining = v08.parseDtcResponse(reread, '03');
      if (mounted) setState(() {
        allCodes.removeWhere((e) => e.status == 'Confirmado');
        allCodes.addAll(remaining);
        codes = remaining.map((e) => e.code).toList();
        status = remaining.isEmpty ? 'Limpeza confirmada; sem DTC confirmado no modo 03'
            : 'Limpeza confirmada; códigos ainda presentes: ' + remaining.length.toString();
      });
      await record('Releitura 03: ' + reread);
    } catch (e) { report(e); }
    finally {
      if (mounted) setState(() => busy = false);
      if (connected) timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    }
  }

  Future<void> disconnect() async {
    timer?.cancel();
    if (sessionReadings.isNotEmpty) { await record('Amostras sensores: ${jsonEncode(sessionReadings)}'); sessionReadings.clear(); }
    await obd.disconnect();
    if (mounted) setState(() { connected = false; status = 'Desconectado'; });
  }
  @override void dispose() { timer?.cancel(); obd.disconnect(); super.dispose(); }
  Widget sectionTitle(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(children: [Icon(icon, color: const Color(0xFF38C7FF)),
      const SizedBox(width: 9), Expanded(child: Text(title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)))]));

  Widget panel({required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF172840),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF294764))),
    child: child);


  Widget get connectionPanel => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: connected ? const Color(0xFF3AE3A4) : Colors.amber),
        const SizedBox(width: 10),
        Expanded(child: Text(status, maxLines: 4, overflow: TextOverflow.ellipsis)),
      ]),
      if (connectingBluetooth) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        const SizedBox(height: 6),
        const Text('Aguarde: estabelecendo comunicação com o adaptador Bluetooth.'),
      ],
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: busy || discovering ? null : scan,
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Dispositivos pareados')),
        if (connected) OutlinedButton.icon(onPressed: busy ? null : disconnect,
          icon: const Icon(Icons.link_off), label: const Text('Desconectar')),
      ]),
      if (!connected) ...devices.map((d) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.settings_input_antenna),
        title: Text(d['name'] ?? 'ELM327'),
        subtitle: Text(d['address'] ?? ''),
        onTap: busy || d['address'] == null ? null : () => connect(d['address']!),
        trailing: const Icon(Icons.chevron_right))),
      if (connected) ...[
        const Divider(),
        Text('Adaptador: $adapterInfo'),
        Text('Protocolo: $protocolInfo'),
        Text('PIDs anunciados: ${supported.length}'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: busy || polling || discovering ? null : discover,
            child: const Text('Descobrir PIDs')),
          OutlinedButton(onPressed: busy || polling || discovering ? null : readVin,
            child: const Text('Consultar VIN bruto')),
        ]),
      ],
      const SizedBox(height: 8),
      const Text('Pareie o ELM327 nas configurações Bluetooth do Android antes de conectar. '
        'A compatibilidade depende do adaptador e do veículo.',
        style: TextStyle(color: Colors.white60, fontSize: 12)),
    ]));

  Widget sensorTile(String pid, IconData icon) {
    final raw = values[pid];
    final available = connected && raw != null && raw != 'Indisponível';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14263E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF275078))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: const Color(0xFF42CFFF), size: 26),
        const SizedBox(height: 12),
        Text(available ? raw : '—', maxLines: 1,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(pids[pid]!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]));
  }

  IconData iconForPid(String pid) {
    switch (pid) {
      case '05': return Icons.thermostat;
      case '0C': return Icons.speed;
      case '42': return Icons.battery_charging_full;
      case '0D': return Icons.route;
      case '0F': return Icons.air;
      default: return Icons.analytics;
    }
  }

  Widget get sensorGrid => LayoutBuilder(builder: (context, constraints) {
    final width = compactSensors ? constraints.maxWidth : (constraints.maxWidth - 12) / 2;
    final visible = sensorOrder.where((pid) => !hiddenSensors.contains(pid));
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final pid in visible)
        SizedBox(width: width, child: sensorTile(pid, iconForPid(pid))),
      if (visible.isEmpty)
        const Text('Nenhum indicador selecionado. Use Personalizar painel.'),
    ]);
  });

  Widget get panelEditor => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      sectionTitle('Personalizar painel', Icons.tune),
      const Text('Arraste o ícone à direita para mudar a ordem. '
        'Use as caixas para mostrar ou ocultar cada indicador.',
        style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 12),
      SizedBox(
        height: sensorOrder.length * 72.0,
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: sensorOrder.length,
          onReorderItem: moveSensor,
          itemBuilder: (context, index) {
            final pid = sensorOrder[index];
            return Card(
              key: ValueKey(pid),
              child: ListTile(
                leading: Checkbox(
                  value: !hiddenSensors.contains(pid),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        hiddenSensors.remove(pid);
                      } else {
                        hiddenSensors.add(pid);
                      }
                    });
                    savePanelPreferences();
                  },
                ),
                title: Text(pids[pid]!),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle, size: 28),
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: resetPanel,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restaurar padrão')),
        FilledButton.icon(
          onPressed: () => setState(() => editingPanel = false),
          icon: const Icon(Icons.check),
          label: const Text('Concluir')),
      ]),
    ],
  );

  Widget get overview => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF1266A8), Color(0xFF102844), Color(0xFF0D1829)]),
        border: Border.all(color: const Color(0xFF3179A6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showVehicleBanner)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(23)),
            child: Image.asset('assets/images/ford_diagnostic_banner.png',
              width: double.infinity, height: 172, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(height: 100,
                child: Center(child: Icon(Icons.directions_car, size: 65))))),
        Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('SEU VEÍCULO', style: TextStyle(
              color: Color(0xFF7DD6FF), letterSpacing: 2, fontSize: 11,
              fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('New Fiesta SE 1.6', style: TextStyle(
              fontSize: 23, fontWeight: FontWeight.w900)),
            const Text('2013/2014  •  PowerShift DPS6',
              style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFF142F49),
                borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: connected ? const Color(0xFF3AE3A4) : Colors.amber),
                const SizedBox(width: 9),
                Expanded(child: Text(connected
                  ? 'ELM327 conectado • dados disponíveis'
                  : 'ELM327 desconectado • conecte para ler dados',
                  style: const TextStyle(fontSize: 12))),
              ])),
          ])),
      ]),
    ),
    const SizedBox(height: 14),
    Row(children: [
      const Expanded(child: Text('Painel de sensores',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
      TextButton.icon(
        onPressed: () => setState(() => editingPanel = !editingPanel),
        icon: Icon(editingPanel ? Icons.close : Icons.tune),
        label: Text(editingPanel ? 'Fechar' : 'Personalizar')),
    ]),
    if (editingPanel) panelEditor else sensorGrid,
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: OutlinedButton.icon(
        onPressed: () => setState(() => selectedTab = 1),
        icon: const Icon(Icons.bluetooth), label: const Text('Conectar'))),
      const SizedBox(width: 8),
      Expanded(child: FilledButton.icon(
        onPressed: () => setState(() => selectedTab = 2),
        icon: const Icon(Icons.car_repair), label: const Text('Diagnóstico'))),
    ]),
    const SizedBox(height: 10),
    const Text('Indicadores exibem somente leituras reais do adaptador OBD2. '
      'Sem conexão, os valores ficam vazios.',
      style: TextStyle(fontSize: 12, color: Colors.white60)),
  ]);

  Widget get settingsView => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Aparência do aplicativo', Icons.palette_outlined),
    panel(child: Column(children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Exibir imagem do veículo'),
        subtitle: const Text('Mostra a imagem no topo do painel'),
        value: showVehicleBanner,
        onChanged: (value) => updateLayout(banner: value)),
      const Divider(),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Indicadores em lista'),
        subtitle: const Text('Um sensor por linha, em vez de duas colunas'),
        value: compactSensors,
        onChanged: (value) => updateLayout(compact: value)),
      const Divider(),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.drag_indicator),
        title: const Text('Reorganizar indicadores'),
        subtitle: const Text('Arrastar, ocultar ou restaurar os sensores'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => setState(() {
          selectedTab = 0;
          editingPanel = true;
        })),
    ])),
    sectionTitle('Sobre o diagnóstico', Icons.info_outline),
    panel(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Ford Diagnostic Pro V0.8 • Em desenvolvimento',
        style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Leitura OBD-II genérica e limpeza de falhas pelo modo 04, '
        'com confirmação e verificações de segurança. Funções Ford aprimoradas, '
        'TCM, adaptações e programação ainda não estão implementadas.'),
      SizedBox(height: 8),
      Text('Não utilize o aplicativo para decisões críticas de segurança '
        'sem confirmar os resultados com equipamento de diagnóstico validado.',
        style: TextStyle(color: Colors.amberAccent)),
    ])),
  ]);

  Widget get diagnostics => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Diagnóstico do motor', Icons.car_repair),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FilledButton.icon(
        onPressed: connected && !busy && !polling && !discovering ? readCodes : null,
        icon: const Icon(Icons.manage_search), label: const Text('Ler falhas confirmadas (03)')),
      const SizedBox(height: 12),
      if (readingDiagnosticCodes) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(diagnosticProgress, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
      ],
      if (!readingDiagnosticCodes && allCodes.isEmpty)
        const Text('Nenhum código exibido. Execute a leitura para consultar.'),
      for (final entry in allCodes) Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(child: Text(entry.code,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                Text(entry.status),
              ]),
              const SizedBox(height: 8),
              Text(entry.description),
              const SizedBox(height: 4),
              const Text('Origem: diagnóstico OBD-II genérico',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Pesquisar este código no Google'),
                onPressed: () async {
                  final uri = Uri.parse(entry.googleUrl);
                  try {
                    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
                    if (!opened) throw StateError('Navegador indisponível');
                  } catch (_) {
                    await Clipboard.setData(ClipboardData(text: entry.googleUrl));
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Não foi possível abrir o navegador. Link copiado.')));
                  }
                },
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
          onPressed: connected && !busy && !polling && !discovering
            ? () => readAdditionalCodes('07', 'Falhas pendentes') : null,
          child: const Text('Pendentes (07)')),
        OutlinedButton(
          onPressed: connected && !busy && !polling && !discovering
            ? () => readAdditionalCodes('0A', 'Falhas permanentes') : null,
          child: const Text('Permanentes (0A)')),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: connected && !busy && !polling && !discovering ? clearGenericCodes : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('Apagar falhas genéricas (04)'),
      ),
      const SizedBox(height: 8),
      const Text('Códigos 03, 07 e 0A exibidos e armazenados. Acesso aprimorado ao TCM ainda não disponível.',
        style: TextStyle(color: Colors.white60, fontSize: 12)),
    ])),
    sectionTitle('PowerShift DPS6 / TCM', Icons.settings),
    panel(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Monitoramento avançado Ford — em desenvolvimento',
        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent)),
      SizedBox(height: 8),
      Text('Leitura específica de TCM, temperatura da transmissão, '
        'atuadores, adaptações e procedimentos de aprendizagem ainda NÃO estão disponíveis.'),
      SizedBox(height: 8),
      Text('Não execute comandos de programação ou testes ativos com adaptador não validado.',
        style: TextStyle(color: Colors.white70)),
    ])),
    sectionTitle('Catálogo de módulos Ford', Icons.memory),
    panel(child: Column(children: [
      const Text('Lista informativa, não representa módulos detectados.',
        style: TextStyle(color: Colors.amberAccent)),
      ...fordModules.map((m) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.lock_outline),
        title: Text('${m.id} — ${m.name}'),
        subtitle: Text(m.bus),
        children: [Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(m.notes))])),
    ])),
  ]);

  Widget get historyView => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Histórico local', Icons.history),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
        onPressed: exportPdf,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Exportar relatório PDF')),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: history.isEmpty ? null : copyHistory,
        icon: const Icon(Icons.copy_all),
        label: const Text('Copiar histórico para exportar')),
      const SizedBox(height: 8),
      Text('${history.length} registros armazenados neste aparelho'),
      const SizedBox(height: 8),
      if (history.isEmpty)
        const Text('Nenhuma consulta registrada ainda.')
      else
        ...history.take(100).map((h) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(h.length > 100 ? '${h.substring(0, 100)}…' : h),
          children: [SelectableText(h)])),
    ])),
    const SizedBox(height: 12),
    const Text('Exportação: copie o histórico e cole em um arquivo de texto, '
      'e-mail ou mensagem. Não há envio automático de dados.',
      style: TextStyle(color: Colors.white60, fontSize: 12)),
  ]);

  Widget get tripStats => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Estatísticas da sessão', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text('Distância: ' + tripKm.toStringAsFixed(2) + ' km'),
      Text('Combustível (estimado): ' + estimatedLiters.toStringAsFixed(2) + ' L'),
      Text('Consumo médio: ' + (estimatedLiters > 0 ? (tripKm / estimatedLiters).toStringAsFixed(1) + ' km/L' : 'Indisponível')),
      Text('Consumo instantâneo: ' + (currentKml == null ? 'Indisponível' : currentKml!.toStringAsFixed(1) + ' km/L')),
      Text('Nível de combustível: ' + (fuelPercent == null ? 'Indisponível' : fuelPercent!.toStringAsFixed(1) + ' %')),
      DropdownButton<v08.FuelType>(
        value: fuelType,
        items: const [
          DropdownMenuItem(value: v08.FuelType.gasoline, child: Text('Gasolina')),
          DropdownMenuItem(value: v08.FuelType.ethanol, child: Text('Etanol')),
        ],
        onChanged: (value) { if (value != null) setState(() { fuelType = value; currentLph = null; currentKml = null; lastTripSample = null; }); },
      ),
      const Text('Consumo estimado pelo MAF, não calibrado para misturas flex ou enriquecimento.',
        style: TextStyle(fontSize: 12, color: Colors.amberAccent)),
      const SizedBox(height: 12),
      const Text('Velocidade • últimas 60 leituras'),
      SizedBox(height: 100, child: CustomPaint(
        painter: _V08LinePainter(speedSamples), child: const SizedBox.expand())),
      const SizedBox(height: 8),
      const Text('Temperatura do motor • últimas 60 leituras'),
      SizedBox(height: 100, child: CustomPaint(
        painter: _V08LinePainter(temperatureSamples), child: const SizedBox.expand())),
    ],
  ));

  Widget get v08Artwork => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Identidade visual V0.8', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Center(child: SizedBox(
        height: 170,
        child: SvgPicture.asset(
          'assets/design_v08/splash_preview.svg',
          fit: BoxFit.contain,
          placeholderBuilder: (_) => const Icon(Icons.directions_car, size: 70),
        ),
      )),
      const Text('Arte vetorial de referência integrada ao aplicativo.',
        style: TextStyle(fontSize: 12, color: Colors.white70)),
    ],
  ));

  Widget get v08Shortcuts => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Acesso rápido • V0.8', Icons.grid_view_rounded),
    LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 12) / 2;
      final items = <(String, IconData, int)>[
        ('Conectar ELM327', Icons.bluetooth_connected, 1),
        ('Códigos de falha', Icons.car_repair, 2),
        ('Sensores em tempo real', Icons.monitor_heart, 0),
        ('Módulos Ford', Icons.memory, 2),
        ('Estatísticas de viagem', Icons.route, 0),
        ('Histórico e relatórios', Icons.description_outlined, 3),
      ];
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final item in items) SizedBox(width: w, child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => selectedTab = item.$3),
          child: Container(
            height: 116, padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF172840),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF295C8D))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(item.$2, color: const Color(0xFF42CFFF), size: 30),
              const Spacer(),
              Text(item.$1, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        )),
      ]);
    }),
    sectionTitle('Indicadores adicionais • V0.8', Icons.analytics_outlined),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Combustível: ' + (connected && fuelPercent != null ? fuelPercent!.toStringAsFixed(1) + ' %' : 'Indisponível')),
      const SizedBox(height: 6),
      Text('Distância percorrida: ' + (connected ? tripKm.toStringAsFixed(2) + ' km (estimada)' : 'Indisponível')),
      const SizedBox(height: 6),
      Text('Consumo instantâneo: ' + (connected && currentKml != null ? currentKml!.toStringAsFixed(1) + ' km/L (estimado)' : 'Indisponível')),
      const SizedBox(height: 6),
      const Text('Temperatura PowerShift: indisponível • PID do TCM não validado',
        style: TextStyle(color: Colors.amberAccent)),
    ])),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ford Diagnostic Pro'),
      actions: [
        Padding(padding: const EdgeInsets.only(right: 14),
          child: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: connected ? const Color(0xFF3AE3A4) : Colors.white54)),
      ]),
    body: ListView(
      key: ValueKey('tela_$selectedTab'),
      padding: const EdgeInsets.all(16),
      children: [
      if (selectedTab == 0) ...[overview, v08Shortcuts, tripStats, v08Artwork],
      if (selectedTab == 1) connectionPanel,
      if (selectedTab == 2) diagnostics,
      if (selectedTab == 3) historyView,
      if (selectedTab == 4) settingsView,
      const SizedBox(height: 18),
      const Text('V0.8 • DIAGNÓSTICO OBD-II GENÉRICO\n'
        'Limpeza genérica 04 com confirmação; testes ativos, adaptações e programação bloqueados.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white54, fontSize: 11)),
    ]),
    bottomNavigationBar: NavigationBar(
      selectedIndex: selectedTab,
      onDestinationSelected: (index) => setState(() => selectedTab = index),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Painel'),
        NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Conexão'),
        NavigationDestination(icon: Icon(Icons.car_repair), label: 'Diagnóstico'),
        NavigationDestination(icon: Icon(Icons.history), label: 'Histórico'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Ajustes'),
      ]),
  );
}


class _V08LinePainter extends CustomPainter {
  final List<double> data;
  _V08LinePainter(this.data);
  @override void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final minVal = data.reduce(math.min);
    final maxVal = data.reduce(math.max);
    final range = math.max(1.0, maxVal - minVal);
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height - ((data[i] - minVal) / range * (size.height - 8)) - 4;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFF42CFFF)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke);
  }
  @override bool shouldRepaint(covariant _V08LinePainter oldDelegate) => true;
}
).hasMatch(response.trim())) {
        throw StateError('A ECU não confirmou a limpeza (resposta: $response).');
      }
      final reread = await obd.command('03');
      final remaining = v08.parseDtcResponse(reread, '03');
      if (mounted) setState(() {
        allCodes.removeWhere((e) => e.status == 'Confirmado');
        allCodes.addAll(remaining);
        codes = remaining.map((e) => e.code).toList();
        status = remaining.isEmpty ? 'Limpeza confirmada; sem DTC confirmado no modo 03'
            : 'Limpeza confirmada; códigos ainda presentes: ' + remaining.length.toString();
      });
      await record('Releitura 03: ' + reread);
    } catch (e) { report(e); }
    finally {
      if (mounted) setState(() => busy = false);
      if (connected) timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    }
  }

  Future<void> disconnect() async {
    timer?.cancel();
    if (sessionReadings.isNotEmpty) { await record('Amostras sensores: ${jsonEncode(sessionReadings)}'); sessionReadings.clear(); }
    await obd.disconnect();
    if (mounted) setState(() { connected = false; status = 'Desconectado'; });
  }
  @override void dispose() { timer?.cancel(); obd.disconnect(); super.dispose(); }
  Widget sectionTitle(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(children: [Icon(icon, color: const Color(0xFF38C7FF)),
      const SizedBox(width: 9), Expanded(child: Text(title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)))]));

  Widget panel({required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF172840),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF294764))),
    child: child);


  Widget get connectionPanel => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: connected ? const Color(0xFF3AE3A4) : Colors.amber),
        const SizedBox(width: 10),
        Expanded(child: Text(status, maxLines: 4, overflow: TextOverflow.ellipsis)),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: busy || discovering ? null : scan,
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Dispositivos pareados')),
        if (connected) OutlinedButton.icon(onPressed: busy ? null : disconnect,
          icon: const Icon(Icons.link_off), label: const Text('Desconectar')),
      ]),
      if (!connected) ...devices.map((d) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.settings_input_antenna),
        title: Text(d['name'] ?? 'ELM327'),
        subtitle: Text(d['address'] ?? ''),
        onTap: busy || d['address'] == null ? null : () => connect(d['address']!),
        trailing: const Icon(Icons.chevron_right))),
      if (connected) ...[
        const Divider(),
        Text('Adaptador: $adapterInfo'),
        Text('Protocolo: $protocolInfo'),
        Text('PIDs anunciados: ${supported.length}'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: busy || polling || discovering ? null : discover,
            child: const Text('Descobrir PIDs')),
          OutlinedButton(onPressed: busy || polling || discovering ? null : readVin,
            child: const Text('Consultar VIN bruto')),
        ]),
      ],
      const SizedBox(height: 8),
      const Text('Pareie o ELM327 nas configurações Bluetooth do Android antes de conectar. '
        'A compatibilidade depende do adaptador e do veículo.',
        style: TextStyle(color: Colors.white60, fontSize: 12)),
    ]));

  Widget sensorTile(String pid, IconData icon) {
    final raw = values[pid];
    final available = connected && raw != null && raw != 'Indisponível';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14263E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF275078))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: const Color(0xFF42CFFF), size: 26),
        const SizedBox(height: 12),
        Text(available ? raw : '—', maxLines: 1,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(pids[pid]!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]));
  }

  IconData iconForPid(String pid) {
    switch (pid) {
      case '05': return Icons.thermostat;
      case '0C': return Icons.speed;
      case '42': return Icons.battery_charging_full;
      case '0D': return Icons.route;
      case '0F': return Icons.air;
      default: return Icons.analytics;
    }
  }

  Widget get sensorGrid => LayoutBuilder(builder: (context, constraints) {
    final width = compactSensors ? constraints.maxWidth : (constraints.maxWidth - 12) / 2;
    final visible = sensorOrder.where((pid) => !hiddenSensors.contains(pid));
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final pid in visible)
        SizedBox(width: width, child: sensorTile(pid, iconForPid(pid))),
      if (visible.isEmpty)
        const Text('Nenhum indicador selecionado. Use Personalizar painel.'),
    ]);
  });

  Widget get panelEditor => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      sectionTitle('Personalizar painel', Icons.tune),
      const Text('Arraste o ícone à direita para mudar a ordem. '
        'Use as caixas para mostrar ou ocultar cada indicador.',
        style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 12),
      SizedBox(
        height: sensorOrder.length * 72.0,
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: sensorOrder.length,
          onReorderItem: moveSensor,
          itemBuilder: (context, index) {
            final pid = sensorOrder[index];
            return Card(
              key: ValueKey(pid),
              child: ListTile(
                leading: Checkbox(
                  value: !hiddenSensors.contains(pid),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        hiddenSensors.remove(pid);
                      } else {
                        hiddenSensors.add(pid);
                      }
                    });
                    savePanelPreferences();
                  },
                ),
                title: Text(pids[pid]!),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle, size: 28),
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: resetPanel,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restaurar padrão')),
        FilledButton.icon(
          onPressed: () => setState(() => editingPanel = false),
          icon: const Icon(Icons.check),
          label: const Text('Concluir')),
      ]),
    ],
  );

  Widget get overview => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF1266A8), Color(0xFF102844), Color(0xFF0D1829)]),
        border: Border.all(color: const Color(0xFF3179A6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showVehicleBanner)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(23)),
            child: Image.asset('assets/images/ford_diagnostic_banner.png',
              width: double.infinity, height: 172, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(height: 100,
                child: Center(child: Icon(Icons.directions_car, size: 65))))),
        Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('SEU VEÍCULO', style: TextStyle(
              color: Color(0xFF7DD6FF), letterSpacing: 2, fontSize: 11,
              fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('New Fiesta SE 1.6', style: TextStyle(
              fontSize: 23, fontWeight: FontWeight.w900)),
            const Text('2013/2014  •  PowerShift DPS6',
              style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFF142F49),
                borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: connected ? const Color(0xFF3AE3A4) : Colors.amber),
                const SizedBox(width: 9),
                Expanded(child: Text(connected
                  ? 'ELM327 conectado • dados disponíveis'
                  : 'ELM327 desconectado • conecte para ler dados',
                  style: const TextStyle(fontSize: 12))),
              ])),
          ])),
      ]),
    ),
    const SizedBox(height: 14),
    Row(children: [
      const Expanded(child: Text('Painel de sensores',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
      TextButton.icon(
        onPressed: () => setState(() => editingPanel = !editingPanel),
        icon: Icon(editingPanel ? Icons.close : Icons.tune),
        label: Text(editingPanel ? 'Fechar' : 'Personalizar')),
    ]),
    if (editingPanel) panelEditor else sensorGrid,
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: OutlinedButton.icon(
        onPressed: () => setState(() => selectedTab = 1),
        icon: const Icon(Icons.bluetooth), label: const Text('Conectar'))),
      const SizedBox(width: 8),
      Expanded(child: FilledButton.icon(
        onPressed: () => setState(() => selectedTab = 2),
        icon: const Icon(Icons.car_repair), label: const Text('Diagnóstico'))),
    ]),
    const SizedBox(height: 10),
    const Text('Indicadores exibem somente leituras reais do adaptador OBD2. '
      'Sem conexão, os valores ficam vazios.',
      style: TextStyle(fontSize: 12, color: Colors.white60)),
  ]);

  Widget get settingsView => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Aparência do aplicativo', Icons.palette_outlined),
    panel(child: Column(children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Exibir imagem do veículo'),
        subtitle: const Text('Mostra a imagem no topo do painel'),
        value: showVehicleBanner,
        onChanged: (value) => updateLayout(banner: value)),
      const Divider(),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Indicadores em lista'),
        subtitle: const Text('Um sensor por linha, em vez de duas colunas'),
        value: compactSensors,
        onChanged: (value) => updateLayout(compact: value)),
      const Divider(),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.drag_indicator),
        title: const Text('Reorganizar indicadores'),
        subtitle: const Text('Arrastar, ocultar ou restaurar os sensores'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => setState(() {
          selectedTab = 0;
          editingPanel = true;
        })),
    ])),
    sectionTitle('Sobre o diagnóstico', Icons.info_outline),
    panel(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Ford Diagnostic Pro V0.8 • Em desenvolvimento',
        style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Leitura OBD-II genérica e limpeza de falhas pelo modo 04, '
        'com confirmação e verificações de segurança. Funções Ford aprimoradas, '
        'TCM, adaptações e programação ainda não estão implementadas.'),
      SizedBox(height: 8),
      Text('Não utilize o aplicativo para decisões críticas de segurança '
        'sem confirmar os resultados com equipamento de diagnóstico validado.',
        style: TextStyle(color: Colors.amberAccent)),
    ])),
  ]);

  Widget get diagnostics => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Diagnóstico do motor', Icons.car_repair),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FilledButton.icon(
        onPressed: connected && !busy && !polling && !discovering ? readCodes : null,
        icon: const Icon(Icons.manage_search), label: const Text('Ler falhas confirmadas (03)')),
      const SizedBox(height: 12),
      if (allCodes.isEmpty) const Text('Nenhum código exibido. Execute a leitura para consultar.'),
      for (final entry in allCodes) ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
        title: Text(entry.code),
        subtitle: Text('${entry.description} • ${entry.status} • Módulo OBD-II genérico'),
        trailing: const Icon(Icons.copy),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: entry.googleUrl));
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link de pesquisa copiado')));
        },
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
          onPressed: connected && !busy && !polling && !discovering
            ? () => readAdditionalCodes('07', 'Falhas pendentes') : null,
          child: const Text('Pendentes (07)')),
        OutlinedButton(
          onPressed: connected && !busy && !polling && !discovering
            ? () => readAdditionalCodes('0A', 'Falhas permanentes') : null,
          child: const Text('Permanentes (0A)')),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: connected && !busy && !polling && !discovering ? clearGenericCodes : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('Apagar falhas genéricas (04)'),
      ),
      const SizedBox(height: 8),
      const Text('Códigos 03, 07 e 0A exibidos e armazenados. Acesso aprimorado ao TCM ainda não disponível.',
        style: TextStyle(color: Colors.white60, fontSize: 12)),
    ])),
    sectionTitle('PowerShift DPS6 / TCM', Icons.settings),
    panel(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Monitoramento avançado Ford — em desenvolvimento',
        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent)),
      SizedBox(height: 8),
      Text('Leitura específica de TCM, temperatura da transmissão, '
        'atuadores, adaptações e procedimentos de aprendizagem ainda NÃO estão disponíveis.'),
      SizedBox(height: 8),
      Text('Não execute comandos de programação ou testes ativos com adaptador não validado.',
        style: TextStyle(color: Colors.white70)),
    ])),
    sectionTitle('Catálogo de módulos Ford', Icons.memory),
    panel(child: Column(children: [
      const Text('Lista informativa, não representa módulos detectados.',
        style: TextStyle(color: Colors.amberAccent)),
      ...fordModules.map((m) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.lock_outline),
        title: Text('${m.id} — ${m.name}'),
        subtitle: Text(m.bus),
        children: [Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(m.notes))])),
    ])),
  ]);

  Widget get historyView => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Histórico local', Icons.history),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
        onPressed: exportPdf,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Exportar relatório PDF')),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: history.isEmpty ? null : copyHistory,
        icon: const Icon(Icons.copy_all),
        label: const Text('Copiar histórico para exportar')),
      const SizedBox(height: 8),
      Text('${history.length} registros armazenados neste aparelho'),
      const SizedBox(height: 8),
      if (history.isEmpty)
        const Text('Nenhuma consulta registrada ainda.')
      else
        ...history.take(100).map((h) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(h.length > 100 ? '${h.substring(0, 100)}…' : h),
          children: [SelectableText(h)])),
    ])),
    const SizedBox(height: 12),
    const Text('Exportação: copie o histórico e cole em um arquivo de texto, '
      'e-mail ou mensagem. Não há envio automático de dados.',
      style: TextStyle(color: Colors.white60, fontSize: 12)),
  ]);

  Widget get tripStats => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Estatísticas da sessão', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text('Distância: ' + tripKm.toStringAsFixed(2) + ' km'),
      Text('Combustível (estimado): ' + estimatedLiters.toStringAsFixed(2) + ' L'),
      Text('Consumo médio: ' + (estimatedLiters > 0 ? (tripKm / estimatedLiters).toStringAsFixed(1) + ' km/L' : 'Indisponível')),
      Text('Consumo instantâneo: ' + (currentKml == null ? 'Indisponível' : currentKml!.toStringAsFixed(1) + ' km/L')),
      Text('Nível de combustível: ' + (fuelPercent == null ? 'Indisponível' : fuelPercent!.toStringAsFixed(1) + ' %')),
      DropdownButton<v08.FuelType>(
        value: fuelType,
        items: const [
          DropdownMenuItem(value: v08.FuelType.gasoline, child: Text('Gasolina')),
          DropdownMenuItem(value: v08.FuelType.ethanol, child: Text('Etanol')),
        ],
        onChanged: (value) { if (value != null) setState(() { fuelType = value; currentLph = null; currentKml = null; lastTripSample = null; }); },
      ),
      const Text('Consumo estimado pelo MAF, não calibrado para misturas flex ou enriquecimento.',
        style: TextStyle(fontSize: 12, color: Colors.amberAccent)),
      const SizedBox(height: 12),
      const Text('Velocidade • últimas 60 leituras'),
      SizedBox(height: 100, child: CustomPaint(
        painter: _V08LinePainter(speedSamples), child: const SizedBox.expand())),
      const SizedBox(height: 8),
      const Text('Temperatura do motor • últimas 60 leituras'),
      SizedBox(height: 100, child: CustomPaint(
        painter: _V08LinePainter(temperatureSamples), child: const SizedBox.expand())),
    ],
  ));

  Widget get v08Artwork => panel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Identidade visual V0.8', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Center(child: SizedBox(
        height: 170,
        child: SvgPicture.asset(
          'assets/design_v08/splash_preview.svg',
          fit: BoxFit.contain,
          placeholderBuilder: (_) => const Icon(Icons.directions_car, size: 70),
        ),
      )),
      const Text('Arte vetorial de referência integrada ao aplicativo.',
        style: TextStyle(fontSize: 12, color: Colors.white70)),
    ],
  ));

  Widget get v08Shortcuts => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    sectionTitle('Acesso rápido • V0.8', Icons.grid_view_rounded),
    LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 12) / 2;
      final items = <(String, IconData, int)>[
        ('Conectar ELM327', Icons.bluetooth_connected, 1),
        ('Códigos de falha', Icons.car_repair, 2),
        ('Sensores em tempo real', Icons.monitor_heart, 0),
        ('Módulos Ford', Icons.memory, 2),
        ('Estatísticas de viagem', Icons.route, 0),
        ('Histórico e relatórios', Icons.description_outlined, 3),
      ];
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final item in items) SizedBox(width: w, child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => selectedTab = item.$3),
          child: Container(
            height: 116, padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF172840),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF295C8D))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(item.$2, color: const Color(0xFF42CFFF), size: 30),
              const Spacer(),
              Text(item.$1, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        )),
      ]);
    }),
    sectionTitle('Indicadores adicionais • V0.8', Icons.analytics_outlined),
    panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Combustível: ' + (connected && fuelPercent != null ? fuelPercent!.toStringAsFixed(1) + ' %' : 'Indisponível')),
      const SizedBox(height: 6),
      Text('Distância percorrida: ' + (connected ? tripKm.toStringAsFixed(2) + ' km (estimada)' : 'Indisponível')),
      const SizedBox(height: 6),
      Text('Consumo instantâneo: ' + (connected && currentKml != null ? currentKml!.toStringAsFixed(1) + ' km/L (estimado)' : 'Indisponível')),
      const SizedBox(height: 6),
      const Text('Temperatura PowerShift: indisponível • PID do TCM não validado',
        style: TextStyle(color: Colors.amberAccent)),
    ])),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ford Diagnostic Pro'),
      actions: [
        Padding(padding: const EdgeInsets.only(right: 14),
          child: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: connected ? const Color(0xFF3AE3A4) : Colors.white54)),
      ]),
    body: ListView(
      key: ValueKey('tela_$selectedTab'),
      padding: const EdgeInsets.all(16),
      children: [
      if (selectedTab == 0) ...[overview, v08Shortcuts, tripStats, v08Artwork],
      if (selectedTab == 1) connectionPanel,
      if (selectedTab == 2) diagnostics,
      if (selectedTab == 3) historyView,
      if (selectedTab == 4) settingsView,
      const SizedBox(height: 18),
      const Text('V0.8 • DIAGNÓSTICO OBD-II GENÉRICO\n'
        'Limpeza genérica 04 com confirmação; testes ativos, adaptações e programação bloqueados.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white54, fontSize: 11)),
    ]),
    bottomNavigationBar: NavigationBar(
      selectedIndex: selectedTab,
      onDestinationSelected: (index) => setState(() => selectedTab = index),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Painel'),
        NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Conexão'),
        NavigationDestination(icon: Icon(Icons.car_repair), label: 'Diagnóstico'),
        NavigationDestination(icon: Icon(Icons.history), label: 'Histórico'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Ajustes'),
      ]),
  );
}


class _V08LinePainter extends CustomPainter {
  final List<double> data;
  _V08LinePainter(this.data);
  @override void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final minVal = data.reduce(math.min);
    final maxVal = data.reduce(math.max);
    final range = math.max(1.0, maxVal - minVal);
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height - ((data[i] - minVal) / range * (size.height - 8)) - 4;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFF42CFFF)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke);
  }
  @override bool shouldRepaint(covariant _V08LinePainter oldDelegate) => true;
}
