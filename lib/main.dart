import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:gbk_codec/gbk_codec.dart';

const double hanpeThreshold = 0.3;
const int rotationBand = 8;  // rank_exit: hold top-8 cheapest by worst(hanPE,hanPB)
const double bigRatioMin = 2.0;  // 大换手: 周均量 ≥ 2× 年均量
const double smallRatioMax = 0.5; // 小换手: 周均量 ≤ ½ 年均量
const int weekDays = 5; // trading days per week
const int yearDays = 250; // trading days per year
const String sinaBase = 'https://vip.stock.finance.sina.com.cn';
const String klineBase = 'https://quotes.sina.cn';

// V-shape detection parameters
const int vsMinDropPct = 20;
const int vsMinRecoveryPct = 30;
const int vsMaxRecoveryPct = 100;
const int vsMinLegDays = 15;
const double vsMinR2 = 0.50;
const int vsMaxBottomAge = 90;
// Combined strategy: trend comparison parameters
const int recentDays = 30;   // window for "current" trend slope
const int priorDays = 60;    // window for "previous" trend slope
const Color accentOrange = Color(0xFFFF9800);

const Color bgBlack = Color(0xFF1A1A2E);  // Dark blue-grey (brightened for visibility)
const Color textOffWhite = Color(0xFFF0F0F0);  // Near-white (brightened)
const Color textMuted = Color(0xFFB0B0B0);  // Light grey (brightened from #9E9E9E)
const Color accentBlue = Color(0xFF64B5F6);  // Lighter blue (brightened)
const Color cardBg = Color(0xFF252540);  // Dark purple-grey (brightened)
const Color cardBorder = Color(0xFF404060);  // Visible border (brightened)

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
      home: const TabbedPage(),
    );
  }
}

class StockData {
  final String code, name, industry;
  final double price, pe, pb, turnover;
  double industryMedianPe, industryMedianPb, hanPe, hanPb, worst;
  int rankWorst = 0;
  double weekYearRatio = 0, weekChangePct = 0;
  double peakVal = 0, bottomVal = 0, recoveryPct = 0;
  double descentR2 = 0, ascentR2 = 0, steepnessRatio = 0;
  int peakIdx = 0, bottomIdx = 0, bottomAge = 0;
  // Combined strategy fields
  double recentSlope = 0, priorSlope = 0, slopeDiff = 0;
  double recentChgPct = 0, priorChgPct = 0;
  StockData({required this.code, required this.name, required this.price, required this.pe, required this.pb, required this.turnover, required this.industry, this.industryMedianPe = 0, this.industryMedianPb = 0, this.hanPe = 0, this.hanPb = 0, this.worst = 0});
}

class KlineDay {
  final double close, volume;
  KlineDay(this.close, this.volume);
}

class SinaService {
  final client = http.Client();
  Future<String> _getGbk(String path, {int retries = 3}) async {
    print('[HTTP] GET $sinaBase$path');
    final stopwatch = Stopwatch()..start();
    for (int attempt = 1; attempt <= retries; attempt++) {
      try {
        final resp = await client.get(Uri.parse(sinaBase + path)).timeout(const Duration(seconds: 15));
        stopwatch.stop();
        print('[HTTP] Response in ${stopwatch.elapsedMilliseconds}ms, status: ${resp.statusCode}, bytes: ${resp.bodyBytes.length}');
        return gbk_bytes.decode(resp.bodyBytes);
      } catch (e) {
        print('[HTTP] Attempt $attempt/$retries failed after ${stopwatch.elapsedMilliseconds}ms: $e');
        if (attempt == retries) {
          stopwatch.stop();
          print('[HTTP] ERROR: All $retries attempts failed');
          rethrow;
        }
        await Future.delayed(Duration(seconds: attempt));  // Exponential backoff
      }
    }
    throw Exception('Unreachable');
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
      try { 
        body = await _getGbk(path); 
      } catch (e) { 
        print('[SECTOR] Error fetching page $page for $industryName: $e');
        break; 
      }
      List<dynamic> data;
      try { 
        data = json.decode(body); 
      } catch (e) { 
        print('[SECTOR] JSON decode error for $industryName page $page: $e');
        break; 
      }
      if (data.isEmpty) break;
      for (final item in data) {
        final symbol = (item['symbol'] as String? ?? '').replaceAll(RegExp(r'^(sh|sz)'), '');
        final code = symbol.padLeft(6, '0');
        final price = _sd(item['trade']);
        final pe = _sd(item['per']);
        final pb = _sd(item['pbs']) ?? _sd(item['pb']);  // Sina uses 'pbs' for 市净率
        final turnover = _sd(item['turnoverratio']);
        final name = item['name'] as String? ?? '';
        if (price != null && pe != null && turnover != null) {
          stocks.add(StockData(code: code, name: name, price: price, pe: pe, pb: pb ?? 0, turnover: turnover, industry: industryName));
        }
      }
      if (data.length < num) break;
      page++;
    }
    print('[SECTOR] $industryName: fetched ${stocks.length} stocks');
    return stocks;
  }
  // Daily k-line (close + volume), last ~250 trading days.
  // 周均换手/年均换手 == 周均成交量/年均成交量 since float shares cancel out.
  Future<List<KlineDay>> fetchKline(String code) async {
    final sym = (code.startsWith('6') ? 'sh' : 'sz') + code;
    final path = '/cn/api/jsonp_v2.php/var%20_kl=/CN_MarketDataService.getKLineData?symbol=$sym&scale=240&ma=no&datalen=$yearDays';
    final resp = await client.get(Uri.parse(klineBase + path)).timeout(const Duration(seconds: 15));
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return [];
    final List<dynamic> data = json.decode(text.substring(start, end + 1));
    final days = <KlineDay>[];
    for (final d in data) {
      final close = double.tryParse(d['close']?.toString() ?? '');
      final vol = double.tryParse(d['volume']?.toString() ?? '');
      if (close != null && vol != null) days.add(KlineDay(close, vol));
    }
    return days;
  }
  double? _sd(dynamic v) { if (v == null || v == '' || v == '-') return null; return double.tryParse(v.toString()); }
  void dispose() => client.close();
}

class ScreenerEngine {
  /// Composite screen: worst = max(hanPE, hanPB), rank all valid stocks ascending.
  /// Returns the full ranked list (rank 1 = cheapest on the composite).
  static List<StockData> run(List<StockData> allRows) {
    // 1. Filter universe
    var df = allRows.where((r) {
      if (!RegExp(r'^(60|00[0-3])').hasMatch(r.code)) return false;
      if (RegExp(r'ST|st|\*ST|退', caseSensitive: false).hasMatch(r.name)) return false;
      if (r.price <= 0 || r.industry.isEmpty) return false;
      return true;
    }).toList();
    // 2. Compute industry median PE and PB
    final peGroups = <String, List<double>>{};
    final pbGroups = <String, List<double>>{};
    for (final r in df) {
      if (r.pe > 0) peGroups.putIfAbsent(r.industry, () => []).add(r.pe);
      if (r.pb > 0) pbGroups.putIfAbsent(r.industry, () => []).add(r.pb);
    }
    final medPe = <String, double>{};
    final medPb = <String, double>{};
    peGroups.forEach((ind, v) { medPe[ind] = _med(v); });
    pbGroups.forEach((ind, v) { medPb[ind] = _med(v); });
    // 3. Compute worst = max(hanPE, hanPB) for stocks where both are valid
    var valid = <StockData>[];
    for (final r in df) {
      if (r.pe <= 0 || r.pb <= 0) continue;
      final mp = medPe[r.industry];
      final mb = medPb[r.industry];
      if (mp == null || mb == null || mp <= 0 || mb <= 0) continue;
      r.industryMedianPe = mp;
      r.industryMedianPb = mb;
      r.hanPe = r.pe / mp;
      r.hanPb = r.pb / mb;
      r.worst = r.hanPe > r.hanPb ? r.hanPe : r.hanPb;  // max(hanPE, hanPB)
      if (r.worst > 0 && r.worst.isFinite) valid.add(r);
    }
    // 4. Rank all valid stocks by worst ascending (rank 1 = cheapest)
    valid.sort((a, b) => a.worst.compareTo(b.worst));
    for (int i = 0; i < valid.length; i++) {
      valid[i].rankWorst = i + 1;
    }
    // Deduplicate by code (keep cheapest occurrence)
    final best = <String, StockData>{};
    for (final c in valid) { final e = best[c.code]; if (e == null || c.worst < e.worst) best[c.code] = c; }
    var result = best.values.toList();
    result.sort((a, b) => a.worst.compareTo(b.worst));
    for (int i = 0; i < result.length; i++) { result[i].rankWorst = i + 1; }
    return result;
  }
  static double _med(List<double> v) { final s = List<double>.from(v)..sort(); final m = s.length ~/ 2; return s.length.isOdd ? s[m] : (s[m-1]+s[m])/2; }
}

class VShapeEngine {
  static double _r2(List<double> values) {
    final n = values.length;
    if (n < 3) return 0.0;
    final meanY = values.reduce((a, b) => a + b) / n;
    var ssTot = 0.0;
    for (final y in values) { ssTot += (y - meanY) * (y - meanY); }
    if (ssTot < 1e-12) return 0.0;
    var ssRes = 0.0;
    for (int i = 0; i < n; i++) {
      final yHat = values[0] + (values[n - 1] - values[0]) * i / (n - 1);
      ssRes += (values[i] - yHat) * (values[i] - yHat);
    }
    return (1.0 - ssRes / ssTot).clamp(0.0, 1.0);
  }

  static Map<String, dynamic>? detect(List<KlineDay> days) {
    if (days.length < 60) return null;
    
    // Validate data: filter out invalid entries
    final closes = <double>[];
    for (final d in days) {
      if (d.close > 0 && d.close.isFinite) {
        closes.add(d.close);
      }
    }
    
    if (closes.length < 60) {
      print('[VSHAPE] Insufficient valid data points: ${closes.length}/${days.length}');
      return null;
    }
    
    final n = closes.length;
    final bottomVal = closes.reduce((a, b) => a < b ? a : b);
    final bottomIdx = closes.indexOf(bottomVal);
    
    // Validate bottom position
    if (bottomIdx < vsMinLegDays || bottomIdx > n - vsMinLegDays - 1) {
      return null;
    }
    
    // Find peak BEFORE bottom (not in entire range)
    final peakSlice = closes.sublist(0, bottomIdx);
    if (peakSlice.isEmpty) return null;
    
    final peakVal = peakSlice.reduce((a, b) => a > b ? a : b);
    final peakIdx = closes.indexOf(peakVal);  // Find first occurrence of peak value
    
    // Validate peak is before bottom and has enough days between them
    if (peakIdx >= bottomIdx) {
      print('[VSHAPE] Invalid peak/bottom order: peakIdx=$peakIdx, bottomIdx=$bottomIdx');
      return null;
    }
    if (bottomIdx - peakIdx < vsMinLegDays) return null;
    
    final current = closes.last;
    final dropPct = (peakVal - bottomVal) / peakVal * 100;
    if (dropPct < vsMinDropPct) return null;
    
    final recoveryAmt = current - bottomVal;
    final dropAmt = peakVal - bottomVal;
    if (dropAmt <= 0) return null;
    
    final recoveryPct = recoveryAmt / dropAmt * 100;
    if (recoveryPct < vsMinRecoveryPct || recoveryPct >= vsMaxRecoveryPct) return null;
    
    final descentDays = bottomIdx - peakIdx;
    final ascentDays = n - 1 - bottomIdx;
    if (descentDays < 1 || ascentDays < 1) return null;
    
    final descentRate = dropPct / descentDays;
    final ascentRate = (recoveryAmt / bottomVal * 100) / ascentDays;
    if (ascentRate <= descentRate) return null;
    
    // Validate sublist ranges before calling _r2
    if (peakIdx >= bottomIdx + 1) {
      print('[VSHAPE] Invalid sublist range for descent: peakIdx=$peakIdx, bottomIdx=$bottomIdx');
      return null;
    }
    
    final r2d = _r2(closes.sublist(peakIdx, bottomIdx + 1));
    final r2a = _r2(closes.sublist(bottomIdx));
    if (r2d < vsMinR2 || r2a < vsMinR2) return null;
    
    final bottomAge = n - 1 - bottomIdx;
    if (bottomAge > vsMaxBottomAge) return null;
    
    return {
      'peakIdx': peakIdx, 'peakVal': peakVal,
      'bottomIdx': bottomIdx, 'bottomVal': bottomVal,
      'recoveryPct': recoveryPct, 'descentR2': r2d, 'ascentR2': r2a,
      'steepnessRatio': ascentRate / descentRate, 'bottomAge': bottomAge,
    };
  }
}

/// Combined strategy: checks if recent rising trend is steeper than prior falling/flat trend.
/// Much simpler than V-shape — just compares two linear regression slopes.
class TrendEngine {
  /// Compute slope as % per day via linear regression.
  static double _slope(List<double> closes) {
    final n = closes.length;
    if (n < 5) return 0.0;
    double meanX = (n - 1) / 2.0;
    double meanY = closes.reduce((a, b) => a + b) / n;
    double cov = 0, varX = 0;
    for (int i = 0; i < n; i++) {
      double dx = i - meanX;
      cov += dx * (closes[i] - meanY);
      varX += dx * dx;
    }
    if (varX < 1e-12) return 0.0;
    return (cov / varX) / meanY * 100;  // % per day
  }

  /// Returns slope comparison result or null if insufficient data / no improvement.
  static Map<String, dynamic>? compare(List<KlineDay> days) {
    final needed = recentDays + priorDays;
    if (days.length < needed) return null;
    final closes = <double>[];
    for (final d in days) {
      if (d.close > 0 && d.close.isFinite) closes.add(d.close);
    }
    if (closes.length < needed) return null;
    final recentCloses = closes.sublist(closes.length - recentDays);
    final priorCloses = closes.sublist(closes.length - needed, closes.length - recentDays);
    final recentSl = _slope(recentCloses);
    final priorSl = _slope(priorCloses);
    if (recentSl <= 0) return null;  // must be actually rising
    if (recentSl <= priorSl) return null;  // must be steeper than prior
    final recentChg = (recentCloses.last / recentCloses.first - 1) * 100;
    final priorChg = (priorCloses.last / priorCloses.first - 1) * 100;
    return {
      'recentSlope': recentSl,
      'priorSlope': priorSl,
      'slopeDiff': recentSl - priorSl,
      'recentChgPct': recentChg,
      'priorChgPct': priorChg,
    };
  }
}

class TabbedPage extends StatefulWidget {
  const TabbedPage({super.key});
  @override
  State<TabbedPage> createState() => _TabbedPageState();
}

class _TabbedPageState extends State<TabbedPage> {
  final SinaService _service = SinaService();
  final AudioPlayer _audio = AudioPlayer();
  
  // hanPE results
  List<StockData> _bigList = [];
  List<StockData> _smallList = [];
  List<StockData> _exitList = [];
  String _hanPeStatus = '';
  bool _hanPeRunning = false;
  
  // Combined strategy results
  List<StockData> _combinedResults = [];
  String _combinedStatus = '';
  bool _combinedRunning = false;
  
  // V-Shape results
  List<StockData> _vShapeResults = [];
  String _vShapeStatus = '';
  bool _vShapeRunning = false;
  
  @override
  void initState() {
    super.initState();
    _runBothScreeners();
  }
  
  Future<void> _runBothScreeners() async {
    print('[APP] Fetching shared sector/stock data...');
    setState(() {
      _hanPeRunning = true; _hanPeStatus = 'Fetching industry sectors...';
      _combinedRunning = true; _combinedStatus = 'Waiting for hanPE...';
      _vShapeRunning = true; _vShapeStatus = 'Fetching industry sectors...';
    });
    List<Map<String, String>> sectors;
    List<StockData> allRows;
    try {
      sectors = await _service.fetchSectors();
      print('[APP] Found ${sectors.length} sectors. Fetching stocks...');
      setState(() {
        _hanPeStatus = 'Found ${sectors.length} industries. Fetching stocks...';
        _vShapeStatus = 'Found ${sectors.length} industries. Fetching stocks...';
      });
      allRows = <StockData>[];
      for (int i = 0; i < sectors.length; i++) {
        final s = sectors[i];
        setState(() {
          _hanPeStatus = '[${i+1}/${sectors.length}] ${s['name']}...';
          _combinedStatus = '[${i+1}/${sectors.length}] ${s['name']}...';
          _vShapeStatus = '[${i+1}/${sectors.length}] ${s['name']}...';
        });
        try { allRows.addAll(await _service.fetchSectorStocks(s['label']!, s['name']!)); } catch (e) { print('[APP] Error: $e'); }
      }
      print('[APP] Fetched ${allRows.length} total stocks. Starting both screeners in parallel...');
    } catch (e) {
      print('[APP] Shared data fetch failed: $e');
      setState(() {
        _hanPeRunning = false; _hanPeStatus = 'Error: $e';
        _combinedRunning = false; _combinedStatus = 'Error: $e';
        _vShapeRunning = false; _vShapeStatus = 'Error: $e';
      });
      return;
    }
    // Execution order optimized for UX:
    // 1. hanPE (fast, ~30s) → shows results immediately
    // 2. Combined (instant, reuses hanPE k-lines) → shows results immediately after hanPE
    // 3. V-Shape (slow, ~3min, scans all stocks) → runs last in background
    final klineCache = await _runHanPeScreener(allRows);
    _runCombinedScreener(klineCache);
    await _runVShapeScreener(allRows);
  }
  
  Future<Map<String, List<KlineDay>>> _runHanPeScreener(List<StockData> allRows) async {
    print('[SCREENER] Starting composite screener...');
    setState(() { _hanPeRunning = true; _hanPeStatus = 'Starting...'; _bigList = []; _smallList = []; _exitList = []; });
    final klineCache = <String, List<KlineDay>>{};
    try {
      if (allRows.isEmpty) {
        setState(() => _hanPeStatus = 'No stock data available');
        return klineCache;
      }
      print('[SCREENER] Total rows: ${allRows.length}');
      setState(() => _hanPeStatus = 'Processing ${allRows.length} rows...');
      // Get full ranked list (all valid stocks sorted by worst ascending)
      final ranked = ScreenerEngine.run(allRows);
      print('[SCREENER] Valid ranked stocks: ${ranked.length}');
      // Take top 50 by worst for k-line enrichment (covers rotation band + threshold band)
      final topN = ranked.take(50).toList();
      final enriched = <StockData>[];
      for (int i = 0; i < topN.length; i++) {
        final c = topN[i];
        setState(() => _hanPeStatus = 'History [${i+1}/${topN.length}] ${c.name}...');
        try {
          final days = await _service.fetchKline(c.code);
          klineCache[c.code] = days;
          if (days.length < weekDays + 1) continue;
          final weekVol = days.sublist(days.length - weekDays).map((d) => d.volume).reduce((a, b) => a + b) / weekDays;
          final yearVol = days.map((d) => d.volume).reduce((a, b) => a + b) / days.length;
          final prevClose = days[days.length - 1 - weekDays].close;
          if (yearVol <= 0 || prevClose <= 0) continue;
          c.weekYearRatio = weekVol / yearVol;
          c.weekChangePct = (days.last.close / prevClose - 1) * 100;
          enriched.add(c);
        } catch (e) { print('[ENRICH] skipped a stock during enrichment: $e'); }
      }
      // Classify by turnover for informational display
      final big = enriched.where((c) => c.weekYearRatio >= bigRatioMin && c.weekChangePct > 0).toList()
        ..sort((a, b) => a.rankWorst.compareTo(b.rankWorst));
      final small = enriched.where((c) => c.weekYearRatio <= smallRatioMax).toList()
        ..sort((a, b) => a.rankWorst.compareTo(b.rankWorst));
      // Exit list = those in the threshold band (worst < 0.3)
      final exitList = enriched.where((c) => c.worst < hanpeThreshold).toList()
        ..sort((a, b) => a.rankWorst.compareTo(b.rankWorst));
      setState(() {
        _bigList = big;
        _smallList = small;
        _exitList = exitList;
        _hanPeStatus = enriched.isEmpty
            ? 'No stocks passed all filters today.'
            : 'Top-$rotationBand: ${enriched.where((c) => c.rankWorst <= rotationBand).length} in band  |  <0.3: ${exitList.length}  |  大换手 ${big.length}  |  小换手 ${small.length}';
      });
      await _notify();
      print('[SCREENER] Completed successfully');
    } catch (e) { 
      print('[SCREENER] ERROR: $e');
      setState(() => _hanPeStatus = 'Error: $e'); 
    }
    finally { 
      print('[SCREENER] Finished, running=false');
      setState(() => _hanPeRunning = false); 
    }
    return klineCache;
  }
  
  /// Composite + upbend: stocks in the rotation band that also pass the trend gate.
  /// Reuses k-lines already fetched by the composite screener (no extra network calls).
  void _runCombinedScreener(Map<String, List<KlineDay>> klineCache) {
    print('[COMBINED] Starting composite+trend on ${klineCache.length} cached k-lines...');
    setState(() { _combinedRunning = true; _combinedStatus = 'Analyzing trends...'; _combinedResults = []; });
    try {
      final results = <StockData>[];
      for (final s in _exitList) {
        final days = klineCache[s.code];
        if (days == null || days.isEmpty) continue;
        final result = TrendEngine.compare(days);
        if (result != null) {
          s.recentSlope = result['recentSlope'];
          s.priorSlope = result['priorSlope'];
          s.slopeDiff = result['slopeDiff'];
          s.recentChgPct = result['recentChgPct'];
          s.priorChgPct = result['priorChgPct'];
          results.add(s);
        }
      }
      // Sort by rank (cheapest first) — the rotation band priority
      results.sort((a, b) => a.rankWorst.compareTo(b.rankWorst));
      final inBand = results.where((s) => s.rankWorst <= rotationBand).length;
      setState(() {
        _combinedResults = results;
        _combinedStatus = results.isEmpty
            ? 'No stocks with upward trend.'
            : '${results.length} cheap+rising ($inBand in top-$rotationBand band)';
      });
      print('[COMBINED] Found ${results.length} stocks with improving trend');
    } catch (e) {
      print('[COMBINED] ERROR: $e');
      setState(() => _combinedStatus = 'Error: $e');
    } finally {
      setState(() => _combinedRunning = false);
    }
  }
  
  Future<void> _runVShapeScreener(List<StockData> allRows) async {
    print('[VSHAPE] Starting V-Shape screener...');
    setState(() { _vShapeRunning = true; _vShapeStatus = 'Starting...'; _vShapeResults = []; });
    try {
      if (allRows.isEmpty) {
        setState(() => _vShapeStatus = 'No stock data available');
        return;
      }
      // Exclude ST/*ST, delisting, B-shares
      final filtered = allRows.where((s) =>
        !RegExp(r'ST|st|\*ST|退', caseSensitive: false).hasMatch(s.name) &&
        !s.code.startsWith('200')
      ).toList();
      setState(() => _vShapeStatus = 'Scanning ${filtered.length} stocks for V-shapes...');
      print('[VSHAPE] Scanning ${filtered.length} stocks');
      final candidates = <StockData>[];
      int klineErrors = 0;
      for (int i = 0; i < filtered.length; i++) {
        final s = filtered[i];
        if (i % 100 == 0) setState(() => _vShapeStatus = 'V-Shape [$i/${filtered.length}]...');
        try {
          final days = await _service.fetchKline(s.code);
          if (days.length < 60) {
            print('[VSHAPE] ${s.code} ${s.name}: insufficient data (${days.length} days)');
            continue;
          }
          final result = VShapeEngine.detect(days);
          if (result != null) {
            s.peakVal = result['peakVal'];
            s.bottomVal = result['bottomVal'];
            s.peakIdx = result['peakIdx'];
            s.bottomIdx = result['bottomIdx'];
            s.recoveryPct = result['recoveryPct'];
            s.descentR2 = result['descentR2'];
            s.ascentR2 = result['ascentR2'];
            s.steepnessRatio = result['steepnessRatio'];
            s.bottomAge = result['bottomAge'];
            candidates.add(s);
            print('[VSHAPE] FOUND: ${s.code} ${s.name} - drop: ${((result['peakVal'] - result['bottomVal']) / result['peakVal'] * 100).toStringAsFixed(1)}%, recovery: ${result['recoveryPct'].toStringAsFixed(1)}%, R2d: ${result['descentR2'].toStringAsFixed(2)}, R2a: ${result['ascentR2'].toStringAsFixed(2)}, steepness: ${result['steepnessRatio'].toStringAsFixed(2)}x');
          }
        } catch (e) {
          klineErrors++;
          if (klineErrors <= 10) print('[VSHAPE] Error fetching kline for ${s.code}: $e');
        }
      }
      print('[VSHAPE] Scan complete: ${candidates.length} candidates, $klineErrors kline errors');
      candidates.sort((a, b) => b.steepnessRatio.compareTo(a.steepnessRatio));
      setState(() {
        _vShapeResults = candidates;
        _vShapeStatus = candidates.isEmpty
            ? 'No V-shaped stocks found today.'
            : 'Found ${candidates.length} V-shaped recoveries';
      });
      await _notify();
      print('[VSHAPE] Completed successfully');
    } catch (e) { 
      print('[VSHAPE] ERROR: $e');
      setState(() => _vShapeStatus = 'Error: $e'); 
    }
    finally { 
      print('[VSHAPE] Finished, running=false');
      setState(() => _vShapeRunning = false); 
    }
  }
  
  Future<void> _notify() async {
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    await HapticFeedback.heavyImpact();
    await _audio.play(AssetSource('beep.wav'), volume: 1.0);
  }
  
  @override
  void dispose() { _service.dispose(); _audio.dispose(); super.dispose(); }
  
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('hanPE Screener'), centerTitle: true,
          bottom: const TabBar(
            tabs: [Tab(text: 'hanPE'), Tab(text: 'Upbend'), Tab(text: 'V-Shape')],
            indicatorColor: accentBlue,
            labelColor: accentBlue,
            unselectedLabelColor: textMuted,
          ),
        ),
        body: TabBarView(children: [
          _HanPeResultsView(
            bigList: _bigList,
            smallList: _smallList,
            status: _hanPeStatus,
            running: _hanPeRunning,
            onRefresh: _runBothScreeners,
          ),
          _CombinedResultsView(
            results: _combinedResults,
            exitList: _exitList,
            status: _combinedStatus,
            running: _combinedRunning,
            onRefresh: _runBothScreeners,
          ),
          _VShapeResultsView(
            results: _vShapeResults,
            status: _vShapeStatus,
            running: _vShapeRunning,
            onRefresh: _runBothScreeners,
          ),
        ]),
      ),
    );
  }
}

class _HanPeResultsView extends StatelessWidget {
  final List<StockData> bigList;
  final List<StockData> smallList;
  final String status;
  final bool running;
  final VoidCallback onRefresh;
  
  const _HanPeResultsView({
    required this.bigList,
    required this.smallList,
    required this.status,
    required this.running,
    required this.onRefresh,
  });
  
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month.toString().padLeft(2,'0')}-${today.day.toString().padLeft(2,'0')}';
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Row(children: [
            Text(dateStr, style: const TextStyle(color: textMuted, fontSize: 12)),
            const Spacer(),
            running ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:textMuted)) : GestureDetector(onTap: onRefresh, child: const Icon(Icons.refresh, size: 18, color: textMuted)),
          ]),
          const Text('worst = max(hanPE, hanPB)  |  Rank 1-8 = rotation band  |  \u5927\u6362\u624b\u22652+\u5468\u6da8  |  \u5c0f\u6362\u624b\u22640.5', style: TextStyle(color: textMuted, fontSize: 10)),
          const SizedBox(height: 6),
          Text(status, style: const TextStyle(color: textMuted, fontSize: 12)),
        ]),
      ),
      Expanded(child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('高换手 (top-50)', style: TextStyle(color: accentBlue, fontSize: 14, fontWeight: FontWeight.bold))),
          if (bigList.isNotEmpty) ...bigList.map((s) => _HanPeCard(s))
          else const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('今日无符合条件的股票', style: TextStyle(color: textMuted, fontSize: 12))),
          const Padding(padding: EdgeInsets.only(top: 12, bottom: 4), child: Text('低换手 (top-50)', style: TextStyle(color: accentBlue, fontSize: 14, fontWeight: FontWeight.bold))),
          if (smallList.isNotEmpty) ...smallList.map((s) => _HanPeCard(s))
          else const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('今日无符合条件的股票', style: TextStyle(color: textMuted, fontSize: 12))),
        ],
      )),
    ]);
  }
}

class _CombinedResultsView extends StatelessWidget {
  final List<StockData> results;
  final List<StockData> exitList;
  final String status;
  final bool running;
  final VoidCallback onRefresh;
  
  const _CombinedResultsView({
    required this.results,
    required this.exitList,
    required this.status,
    required this.running,
    required this.onRefresh,
  });
  
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month.toString().padLeft(2,'0')}-${today.day.toString().padLeft(2,'0')}';
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Row(children: [
            Text(dateStr, style: const TextStyle(color: textMuted, fontSize: 12)),
            const Spacer(),
            running ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:textMuted)) : GestureDetector(onTap: onRefresh, child: const Icon(Icons.refresh, size: 18, color: textMuted)),
          ]),
          const Text('worst < 0.3 + upbend (30d slope > 0 > prior 60d)', style: TextStyle(color: textMuted, fontSize: 11)),
          const SizedBox(height: 6),
          Text(status, style: const TextStyle(color: textMuted, fontSize: 12)),
        ]),
      ),
      Expanded(child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('BUY (upbend pass)', style: TextStyle(color: Color(0xFF00E676), fontSize: 14, fontWeight: FontWeight.bold))),
          if (results.isNotEmpty) ...results.map((s) => _CombinedCard(s))
          else const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('\u65e0\u80a1\u7968\u901a\u8fc7\u8d8b\u52bf\u95e8\u69db', style: TextStyle(color: textMuted, fontSize: 12))),
          const Padding(padding: EdgeInsets.only(top: 12, bottom: 4), child: Text('WATCH (cheap, not rising)', style: TextStyle(color: accentOrange, fontSize: 14, fontWeight: FontWeight.bold))),
          ..._watchList().map((s) => _HanPeCard(s)),
          if (_watchList().isEmpty) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('\u65e0\u5f85\u89c2\u5bdf\u80a1\u7968', style: TextStyle(color: textMuted, fontSize: 12))),
        ],
      )),
    ]);
  }

  List<StockData> _watchList() {
    final passed = results.map((s) => s.code).toSet();
    return exitList.where((s) => !passed.contains(s.code)).toList()
      ..sort((a, b) => a.rankWorst.compareTo(b.rankWorst));
  }
}

class _VShapeResultsView extends StatelessWidget {
  final List<StockData> results;
  final String status;
  final bool running;
  final VoidCallback onRefresh;
  
  const _VShapeResultsView({
    required this.results,
    required this.status,
    required this.running,
    required this.onRefresh,
  });
  
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month.toString().padLeft(2,'0')}-${today.day.toString().padLeft(2,'0')}';
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Row(children: [
            Text(dateStr, style: const TextStyle(color: textMuted, fontSize: 12)),
            const Spacer(),
            running ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:textMuted)) : GestureDetector(onTap: onRefresh, child: const Icon(Icons.refresh, size: 18, color: textMuted)),
          ]),
          const Text('Drop>=20%  Recovery>=30%  Ascent>Descent  R2>=0.5  Bottom<=90d', style: TextStyle(color: textMuted, fontSize: 10)),
          const SizedBox(height: 6),
          Text(status, style: const TextStyle(color: textMuted, fontSize: 12)),
        ]),
      ),
      Expanded(child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: results.map((s) => _VCard(s)).toList(),
      )),
    ]);
  }
}





class _HanPeCard extends StatelessWidget {
  final StockData s;
  const _HanPeCard(this.s);
  @override
  Widget build(BuildContext context) {
    final inBand = s.rankWorst <= rotationBand;
    final bandColor = inBand ? const Color(0xFF4CAF50) : accentBlue;
    final chgColor = s.weekChangePct > 0 ? const Color(0xFFEF5350) : (s.weekChangePct < 0 ? const Color(0xFF66BB6A) : textMuted);
    return Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: inBand ? bandColor : cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(color: bandColor.withOpacity(0.2), borderRadius: BorderRadius.circular(3)),
            child: Text('#${s.rankWorst}', style: TextStyle(color: bandColor, fontSize: 11, fontWeight: FontWeight.bold))),
          const SizedBox(width: 6),
          Text(s.code, style: const TextStyle(color: textOffWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Expanded(child: Text(s.name, style: const TextStyle(color: textOffWhite, fontSize: 13))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: bandColor.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
            child: Text('worst ${s.worst.toStringAsFixed(3)}', style: TextStyle(color: bandColor, fontSize: 12, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 8),
        Row(children: [_M('hanPE', s.hanPe.toStringAsFixed(3)), _M('hanPB', s.hanPb.toStringAsFixed(3)), _M('PE', s.pe.toStringAsFixed(1)), _M('PB', s.pb.toStringAsFixed(2)), _M('周年比', s.weekYearRatio.toStringAsFixed(2)), _M('周涨幅', '${s.weekChangePct >= 0 ? '+' : ''}${s.weekChangePct.toStringAsFixed(1)}%', valueColor: chgColor)]),
        const SizedBox(height: 4),
        Row(children: [const Text('行业', style: TextStyle(color: textMuted, fontSize: 10)), const SizedBox(width: 4), Expanded(child: Text(s.industry, style: const TextStyle(color: textOffWhite, fontSize: 11)))]),
      ]),
    );
  }
}

class _CombinedCard extends StatelessWidget {
  final StockData s;
  const _CombinedCard(this.s);
  @override
  Widget build(BuildContext context) {
    final isRising = s.recentSlope > 0;
    final trendIcon = isRising ? '↑' : '↓';
    final trendColor = isRising ? const Color(0xFFEF5350) : const Color(0xFFFF9800);
    final inBand = s.rankWorst <= rotationBand;
    final bandColor = inBand ? const Color(0xFF4CAF50) : textMuted;
    final priorColor = s.priorChgPct > 0 ? const Color(0xFFEF5350) : (s.priorChgPct < 0 ? const Color(0xFF66BB6A) : textMuted);
    final recentColor = s.recentChgPct > 0 ? const Color(0xFFEF5350) : (s.recentChgPct < 0 ? const Color(0xFF66BB6A) : textMuted);
    return Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: inBand ? const Color(0xFF4CAF50) : cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(color: bandColor.withOpacity(0.2), borderRadius: BorderRadius.circular(3)),
            child: Text('#${s.rankWorst}', style: TextStyle(color: bandColor, fontSize: 11, fontWeight: FontWeight.bold))),
          const SizedBox(width: 6),
          Text(s.code, style: const TextStyle(color: textOffWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Expanded(child: Text(s.name, style: const TextStyle(color: textOffWhite, fontSize: 13))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: trendColor.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
            child: Text('$trendIcon ${s.slopeDiff.toStringAsFixed(3)}', style: TextStyle(color: trendColor, fontSize: 12, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _M('worst', s.worst.toStringAsFixed(3)),
          _M('hanPE', s.hanPe.toStringAsFixed(3)),
          _M('hanPB', s.hanPb.toStringAsFixed(3)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          _M('前60日', '${s.priorChgPct >= 0 ? "+" : ""}${s.priorChgPct.toStringAsFixed(1)}%', valueColor: priorColor),
          _M('近30日', '${s.recentChgPct >= 0 ? "+" : ""}${s.recentChgPct.toStringAsFixed(1)}%', valueColor: recentColor),
          _M('斜率差', s.slopeDiff.toStringAsFixed(3)),
        ]),
        const SizedBox(height: 4),
        Row(children: [const Text('行业', style: TextStyle(color: textMuted, fontSize: 10)), const SizedBox(width: 4), Expanded(child: Text(s.industry, style: const TextStyle(color: textOffWhite, fontSize: 11)))]),
      ]),
    );
  }
}

class _VCard extends StatelessWidget {
  final StockData s;
  const _VCard(this.s);
  @override
  Widget build(BuildContext context) {
    final dropPct = s.peakVal > 0 ? (s.peakVal - s.bottomVal) / s.peakVal * 100 : 0.0;
    return Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(s.code, style: const TextStyle(color: textOffWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Expanded(child: Text(s.name, style: const TextStyle(color: textOffWhite, fontSize: 13))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: accentOrange.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
            child: Text('${s.steepnessRatio.toStringAsFixed(1)}x', style: const TextStyle(color: accentOrange, fontSize: 12, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _M('Peak', s.peakVal.toStringAsFixed(2)),
          _M('Bottom', s.bottomVal.toStringAsFixed(2)),
          _M('Current', s.price.toStringAsFixed(2)),
          _M('Drop', '${dropPct.toStringAsFixed(0)}%'),
          _M('Recovery', '${s.recoveryPct.toStringAsFixed(0)}%'),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          _M('Descent R2', s.descentR2.toStringAsFixed(2)),
          _M('Ascent R2', s.ascentR2.toStringAsFixed(2)),
          _M('Bottom', '${s.bottomAge}d ago'),
          _M('行业', s.industry),
        ]),
      ]),
    );
  }
}

class _M extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _M(this.label, this.value, {this.valueColor});
  @override
  Widget build(BuildContext context) {
    return Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: textMuted, fontSize: 10)),
      Text(value, style: TextStyle(color: valueColor ?? textOffWhite, fontSize: 12)),
    ]));
  }
}