import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:gbk_codec/gbk_codec.dart';

const double hanpeThreshold = 0.3;
const int turnoverPercentile = 70;
const String sinaBase = 'https://vip.stock.finance.sina.com.cn';

const Color bgBlack = Color(0xFF000000);
const Color textOffWhite = Color(0xFFE0E0E0);
const Color textMuted = Color(0xFF9E9E9E);
const Color accentBlue = Color(0xFF42A5F5);
const Color cardBg = Color(0xFF111111);
const Color cardBorder = Color(0xFF222222);

void main() => runApp(const HanPeApp());

class HanPeApp extends StatelessWidget {
  const HanPeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hanPE Screener',
      theme: ThemeData(
        scaffoldBackgroundColor: bgBlack,
        colorScheme: const ColorScheme.dark(primary: accentBlue, surface: bgBlack, onSurface: textOffWhite),
        appBarTheme: const AppBarTheme(
          backgroundColor: bgBlack, elevation: 0,
          titleTextStyle: TextStyle(color: textOffWhite, fontSize: 16, fontWeight: FontWeight.w500),
          iconTheme: IconThemeData(color: textOffWhite),
        ),
        useMaterial3: true, brightness: Brightness.dark,
      ),
      home: const ScreenerPage(),
    );
  }
}

class StockData {
  final String code, name, industry;
  final double price, pe, turnover;
  double industryMedianPe, hanPe;
  StockData({required this.code, required this.name, required this.price, required this.pe, required this.turnover, required this.industry, this.industryMedianPe = 0, this.hanPe = 0});
}

class SinaService {
  final client = http.Client();
  Future<String> _getGbk(String path) async {
    final resp = await client.get(Uri.parse(sinaBase + path)).timeout(const Duration(seconds: 15));
    return gbk_bytes.decode(resp.bodyBytes);
  }
  Future<List<Map<String, String>>> fetchSectors() async {
    final text = await _getGbk('/q/view/newSinaHy.php');
    final jsonStr = text.substring(text.indexOf('{'));
    final Map<String, dynamic> data = json.decode(jsonStr);
    final sectors = <Map<String, String>>[];
    data.forEach((label, value) {
      final parts = (value as String).split(',');
      sectors.add({'label': label, 'name': parts.length > 1 ? parts[1] : label});
    });
    return sectors;
  }
  Future<List<StockData>> fetchSectorStocks(String node, String industryName) async {
    final stocks = <StockData>[];
    int page = 1;
    const num = 80;
    while (true) {
      final path = '/quotes_service/api/json_v2.php/Market_Center.getHQNodeData?page=$page&num=$num&sort=symbol&asc=1&node=$node&_s_r_a=page';
      String body;
      try { body = await _getGbk(path); } catch (_) { break; }
      List<dynamic> data;
      try { data = json.decode(body); } catch (_) { break; }
      if (data.isEmpty) break;
      for (final item in data) {
        final symbol = (item['symbol'] as String? ?? '').replaceAll(RegExp(r'^(sh|sz)'), '');
        final code = symbol.padLeft(6, '0');
        final price = _sd(item['trade']);
        final pe = _sd(item['per']);
        final turnover = _sd(item['turnoverratio']);
        final name = item['name'] as String? ?? '';
        if (price != null && pe != null && turnover != null) {
          stocks.add(StockData(code: code, name: name, price: price, pe: pe, turnover: turnover, industry: industryName));
        }
      }
      if (data.length < num) break;
      page++;
    }
    return stocks;
  }
  double? _sd(dynamic v) { if (v == null || v == '' || v == '-') return null; return double.tryParse(v.toString()); }
  void dispose() => client.close();
}

class ScreenerEngine {
  static List<StockData> run(List<StockData> allRows) {
    var df = allRows.where((r) {
      if (!RegExp(r'^(60|00[0-3])').hasMatch(r.code)) return false;
      if (RegExp(r'ST|st|\*ST|退', caseSensitive: false).hasMatch(r.name)) return false;
      if (r.price <= 0 || r.industry.isEmpty) return false;
      return true;
    }).toList();
    final indGroups = <String, List<double>>{};
    for (final r in df) indGroups.putIfAbsent(r.industry, () => []).add(r.pe);
    final indMedian = <String, double>{};
    indGroups.forEach((ind, pes) { indMedian[ind] = _med(pes); });
    final uTurn = <String, double>{};
    for (final r in df) { final c = uTurn[r.code]; if (c == null || r.turnover > c) uTurn[r.code] = r.turnover; }
    final sorted = uTurn.values.toList()..sort();
    final pIdx = (sorted.length * turnoverPercentile / 100).floor();
    final tThreshold = pIdx < sorted.length ? sorted[pIdx] : 0.0;
    var cands = <StockData>[];
    for (final r in df) {
      if (r.pe <= 0) continue;
      final med = indMedian[r.industry];
      if (med == null) continue;
      r.industryMedianPe = med;
      r.hanPe = r.pe / med;
      if (r.hanPe > 0 && r.hanPe < hanpeThreshold && r.turnover >= tThreshold) cands.add(r);
    }
    final best = <String, StockData>{};
    for (final c in cands) { final e = best[c.code]; if (e == null || c.hanPe < e.hanPe) best[c.code] = c; }
    cands = best.values.toList();
    cands.sort((a, b) => a.hanPe.compareTo(b.hanPe));
    return cands;
  }
  static double _med(List<double> v) { final s = List<double>.from(v)..sort(); final m = s.length ~/ 2; return s.length.isOdd ? s[m] : (s[m-1]+s[m])/2; }
}

class ScreenerPage extends StatefulWidget {
  const ScreenerPage({super.key});
  @override
  State<ScreenerPage> createState() => _ScreenerPageState();
}

class _ScreenerPageState extends State<ScreenerPage> {
  final SinaService _service = SinaService();
  final AudioPlayer _audio = AudioPlayer();
  List<StockData> _results = [];
  String _status = '';
  bool _running = false;
  double _tThreshold = 0;

  @override
  void initState() { super.initState(); _runScreener(); }

  Future<void> _notify() async {
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    await HapticFeedback.heavyImpact();
    await _audio.play(AssetSource('beep.wav'), volume: 1.0);
  }

  Future<void> _runScreener() async {
    setState(() { _running = true; _status = 'Starting...'; _results = []; });
    try {
      setState(() => _status = 'Fetching industry sectors...');
      final sectors = await _service.fetchSectors();
      setState(() => _status = 'Found ${sectors.length} industries. Fetching stocks...');
      var allRows = <StockData>[];
      for (int i = 0; i < sectors.length; i++) {
        final s = sectors[i];
        setState(() => _status = '[${i+1}/${sectors.length}] ${s['name']}...');
        try { allRows.addAll(await _service.fetchSectorStocks(s['label']!, s['name']!)); } catch (_) {}
      }
      setState(() => _status = 'Processing ${allRows.length} rows...');
      final results = ScreenerEngine.run(allRows);
      final uTurn = <String, double>{};
      for (final r in allRows) { final c = uTurn[r.code]; if (c == null || r.turnover > c) uTurn[r.code] = r.turnover; }
      final sorted = uTurn.values.toList()..sort();
      final pIdx = (sorted.length * turnoverPercentile / 100).floor();
      _tThreshold = pIdx < sorted.length ? sorted[pIdx] : 0.0;
      setState(() {
        _results = results;
        _status = results.isEmpty ? 'No stocks passed all filters today.' : 'Found ${results.length} ultra-low valuation stocks';
      });
      await _notify();
    } catch (e) { setState(() => _status = 'Error: $e'); }
    finally { setState(() => _running = false); }
  }

  @override
  void dispose() { _service.dispose(); _audio.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month.toString().padLeft(2,'0')}-${today.day.toString().padLeft(2,'0')}';
    return Scaffold(
      appBar: AppBar(
        title: const Text('hanPE Screener'), centerTitle: true,
        actions: [IconButton(icon: _running ? const SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2,color:textOffWhite)) : const Icon(Icons.refresh), onPressed: _running ? null : _runScreener, tooltip: 'Refresh')],
      ),
      body: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(dateStr, style: const TextStyle(color: textMuted, fontSize: 12)),
            const Text('hanPE < 0.3  |  Turnover: Top 30%', style: TextStyle(color: textMuted, fontSize: 11)),
            const SizedBox(height: 6),
            Text(_status, style: const TextStyle(fontSize: 12, color: textMuted)),
            if (_tThreshold > 0) Text('P$turnoverPercentile: ${_tThreshold.toStringAsFixed(2)}%', style: const TextStyle(fontSize: 11, color: textMuted)),
          ]),
        ),
        if (_results.isNotEmpty) _buildCards(),
      ]),
    );
  }

  Widget _buildCards() {
    return Expanded(child: ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final s = _results[i];
        return Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: cardBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(s.code, style: const TextStyle(color: textOffWhite, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(child: Text(s.name, style: const TextStyle(color: textOffWhite, fontSize: 13))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: accentBlue.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                child: Text('hanPE ${s.hanPe.toStringAsFixed(3)}', style: const TextStyle(color: accentBlue, fontSize: 12, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            Row(children: [_M('价格', s.price.toStringAsFixed(2)), _M('PE', s.pe.toStringAsFixed(1)), _M('行业PE', s.industryMedianPe.toStringAsFixed(1)), _M('换手%', s.turnover.toStringAsFixed(1))]),
            const SizedBox(height: 4),
            Row(children: [const Text('行业', style: TextStyle(color: textMuted, fontSize: 10)), const SizedBox(width: 4), Expanded(child: Text(s.industry, style: const TextStyle(color: textOffWhite, fontSize: 11)))]),
          ]),
        );
      },
    ));
  }
}

class _M extends StatelessWidget {
  final String label, value;
  const _M(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    return Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: textMuted, fontSize: 10)),
      Text(value, style: const TextStyle(color: textOffWhite, fontSize: 12)),
    ]));
  }
}
