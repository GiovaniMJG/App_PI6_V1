import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'firebase_options.dart';
import 'registros.dart';

// Períodos do histórico.
enum PeriodoHistorico {
  cincoMinutos('5 min', Duration(minutes: 5), 1),
  quinzeMinutos('15 min', Duration(minutes: 15), 5),
  meiaHora('30 min', Duration(minutes: 30), 10),
  umaHora('1 h', Duration(hours: 1), 15);

  final String label;
  final Duration duracao;
  final int minutosEntreMarcacoes; // espaçamento dos rótulos do eixo X
  const PeriodoHistorico(this.label, this.duracao, this.minutosEntreMarcacoes);
}

// Pontos por gráfico; as leituras são agrupadas por faixa de tempo.
const int pontosPorGrafico = 30;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
  // Sem await: sem internet, a inscrição no tópico demora e travaria a abertura.
  unawaited(_configurarNotificacoes());
}

// Exibe as notificações enquanto o app está aberto.
final FlutterLocalNotificationsPlugin _notificacoesLocais =
    FlutterLocalNotificationsPlugin();

// Canal Android dos alertas; o push com o app fechado usa o mesmo canal
// (AndroidManifest.xml).
const AndroidNotificationChannel _canalAlertas = AndroidNotificationChannel(
  'alertas',
  'Alertas da estufa',
  description: 'Temperatura ou umidade fora da faixa segura',
  importance: Importance.high,
);

// Push (FCM): inscrição no tópico "alertas", enviado pelo simulador.
// Só no Android: a web não tem tópicos e o iOS não foi configurado.
Future<void> _configurarNotificacoes() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _notificacoesLocais.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _notificacoesLocais
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_canalAlertas);

    final fcm = FirebaseMessaging.instance;
    await fcm.requestPermission();
    // Com o app aberto, o Android entrega o push ao app sem exibi-lo.
    FirebaseMessaging.onMessage.listen(_exibirNotificacao);
    await fcm.subscribeToTopic('alertas');
  } catch (erro) {
    debugPrint('Não foi possível ativar as notificações: $erro');
  }
}

void _exibirNotificacao(RemoteMessage mensagem) {
  final RemoteNotification? notificacao = mensagem.notification;
  if (notificacao == null) return;
  _notificacoesLocais.show(
    id: mensagem.messageId.hashCode,
    title: notificacao.title,
    body: notificacao.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _canalAlertas.id,
        _canalAlertas.name,
        channelDescription: _canalAlertas.description,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitor Estufa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const _TelaPrincipal(),
    );
  }
}

// Barra inferior com as abas "Agora" e "Registros".
class _TelaPrincipal extends StatefulWidget {
  const _TelaPrincipal();

  @override
  State<_TelaPrincipal> createState() => _TelaPrincipalState();
}

class _TelaPrincipalState extends State<_TelaPrincipal> {
  int _aba = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack mantém as duas abas vivas (sem recarregar ao trocar).
      body: IndexedStack(
        index: _aba,
        children: const [EstufaHomePage(), RegistrosPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _aba,
        onDestinationSelected: (i) => setState(() => _aba = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.thermostat), label: 'Agora'),
          NavigationDestination(
            icon: Icon(Icons.event_note),
            label: 'Registros',
          ),
        ],
      ),
    );
  }
}

// Era verde e vermelho, modificada por conta do daltonismo
const Color corPerigo = Colors.red;
const Color corSegura = Colors.blue;

// Limites da ficha de controle da empresa (FOR 6.3.3). Só há máximo.
const double temperaturaMax = 20.0;
const double umidadeMax = 60.0;

const double temperaturaGraficoMin = 0.0;
const double temperaturaGraficoMax = 40.0;
const double umidadeGraficoMin = 0.0;
const double umidadeGraficoMax = 100.0;

// Formatação de horário (09:05 e 09:05:30).
String _doisDigitos(int n) => n.toString().padLeft(2, '0');
String _horaMinuto(DateTime t) =>
    '${_doisDigitos(t.hour)}:${_doisDigitos(t.minute)}';
String _horaCompleta(DateTime t) =>
    '${_horaMinuto(t)}:${_doisDigitos(t.second)}';
String _diaMes(DateTime t) => '${_doisDigitos(t.day)}/${_doisDigitos(t.month)}';

class EstufaHomePage extends StatelessWidget {
  const EstufaHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final leituraRef = FirebaseFirestore.instance
        .collection('estufa')
        .doc('leitura_atual');

    return Scaffold(
      appBar: AppBar(title: const Text('Monitoramento da Estufa')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: leituraRef.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Erro: ${snapshot.error}'));
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }

          final dados = snapshot.data!.data() as Map<String, dynamic>;
          // num: aceita valor gravado como inteiro (ex.: firmware do ESP32).
          final double temperatura = (dados['temperatura'] as num).toDouble();
          final double umidade = (dados['umidade'] as num).toDouble();

          final bool temperaturaPerigo = temperatura > temperaturaMax;
          final bool umidadePerigo = umidade > umidadeMax;

          final bool emPerigo = temperaturaPerigo || umidadePerigo;

          return SingleChildScrollView(
            child: Column(
              // Largura total, mantém o conteúdo centralizado.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (emPerigo)
                  _AlertaPerigo(
                    temperaturaPerigo: temperaturaPerigo,
                    umidadePerigo: umidadePerigo,
                  ),
                const SizedBox(height: 24),
                _MedidaCard(
                  label: 'Temperatura',
                  valorTexto: '${decimal(temperatura)} °C',
                  perigo: temperaturaPerigo,
                ),
                const SizedBox(height: 32),
                _MedidaCard(
                  label: 'Umidade',
                  valorTexto: '${decimal(umidade)} %',
                  perigo: umidadePerigo,
                ),
                const SizedBox(height: 32),
                const _PainelHistorico(),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}

// Leitura do histórico.
class LeituraHistorico {
  const LeituraHistorico(this.horario, this.temperatura, this.umidade);

  final DateTime horario;
  final double temperatura;
  final double umidade;
}

// Ponto do gráfico: média das leituras de uma faixa de tempo.
class PontoGrafico {
  const PontoGrafico({
    required this.horario,
    required this.primeira,
    required this.ultima,
    required this.media,
    required this.maximo,
    required this.horarioMaximo,
    required this.quantidade,
  });

  final DateTime
  horario; // horário médio das leituras da faixa (posição no eixo X)
  final DateTime primeira; // captura da primeira leitura da faixa
  final DateTime ultima; // captura da última leitura da faixa
  final double media;
  final double maximo;
  final DateTime horarioMaximo; // captura da leitura de valor máximo
  final int quantidade;
}

// Seletor de período e gráficos; uma única consulta alimenta os dois.
class _PainelHistorico extends StatefulWidget {
  const _PainelHistorico();

  @override
  State<_PainelHistorico> createState() => _PainelHistoricoState();
}

class _PainelHistoricoState extends State<_PainelHistorico> {
  PeriodoHistorico _periodo = PeriodoHistorico.quinzeMinutos;
  late DateTime _inicioConsulta;
  late Stream<QuerySnapshot> _consulta;
  late final Timer _relogio;

  @override
  void initState() {
    super.initState();
    _montarConsulta();
    // Atualiza a janela de tempo a cada 30 s, mesmo sem leituras novas.
    _relogio = Timer.periodic(const Duration(seconds: 30), (_) {
      setState(() {
        // Renova a consulta quando ela acumula leituras antigas demais.
        if (DateTime.now().difference(_inicioConsulta) > _periodo.duracao * 2) {
          _montarConsulta();
        }
      });
    });
  }

  @override
  void dispose() {
    _relogio.cancel();
    super.dispose();
  }

  // Consulta mantida no estado: recriá-la no build releria todo o período
  // a cada nova leitura, consumindo a cota do Firestore.
  void _montarConsulta() {
    _inicioConsulta = DateTime.now().subtract(_periodo.duracao);
    _consulta = FirebaseFirestore.instance
        .collection('estufa')
        .doc('leitura_atual')
        .collection('historico')
        .where(
          'timestamp',
          isGreaterThanOrEqualTo: Timestamp.fromDate(_inicioConsulta),
        )
        .orderBy('timestamp')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text('Histórico', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        SegmentedButton<PeriodoHistorico>(
          showSelectedIcon: false,
          segments: [
            for (final periodo in PeriodoHistorico.values)
              ButtonSegment(value: periodo, label: Text(periodo.label)),
          ],
          selected: {_periodo},
          onSelectionChanged: (selecionados) {
            setState(() {
              _periodo = selecionados.first;
              _montarConsulta();
            });
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<QuerySnapshot>(
          stream: _consulta,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text('Erro ao carregar o histórico: ${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              );
            }

            // Janela exibida: do horário atual para trás.
            final DateTime inicio = DateTime.now().subtract(_periodo.duracao);
            final leituras = [
              for (final doc in snapshot.data!.docs)
                if (doc.data() case final Map<String, dynamic> dados)
                  LeituraHistorico(
                    (dados['timestamp'] as Timestamp).toDate(),
                    (dados['temperatura'] as num).toDouble(),
                    (dados['umidade'] as num).toDouble(),
                  ),
            ].where((l) => !l.horario.isBefore(inicio)).toList();

            if (leituras.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Nenhuma leitura neste período.\n'
                  'Aguardando leituras do sensor.',
                  textAlign: TextAlign.center,
                ),
              );
            }

            return Column(
              children: [
                _GraficoHistorico(
                  titulo: 'Temperatura',
                  unidade: '°C',
                  limite: temperaturaMax,
                  eixoMin: temperaturaGraficoMin,
                  eixoMax: temperaturaGraficoMax,
                  inicio: inicio,
                  periodo: _periodo,
                  pontos: agruparLeituras(
                    leituras,
                    inicio,
                    _periodo.duracao,
                    (l) => l.temperatura,
                  ),
                ),
                const SizedBox(height: 24),
                _GraficoHistorico(
                  titulo: 'Umidade',
                  unidade: '%',
                  limite: umidadeMax,
                  eixoMin: umidadeGraficoMin,
                  eixoMax: umidadeGraficoMax,
                  inicio: inicio,
                  periodo: _periodo,
                  pontos: agruparLeituras(
                    leituras,
                    inicio,
                    _periodo.duracao,
                    (l) => l.umidade,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// Agrupa as leituras em faixas de tempo iguais (média e máximo).
List<PontoGrafico> agruparLeituras(
  List<LeituraHistorico> leituras,
  DateTime inicio,
  Duration duracao,
  double Function(LeituraHistorico) valorDe,
) {
  final double segundosPorFaixa = duracao.inSeconds / pontosPorGrafico;
  final faixas = <int, List<LeituraHistorico>>{};
  for (final l in leituras) {
    final int indice =
        (l.horario.difference(inicio).inSeconds / segundosPorFaixa)
            .floor()
            .clamp(0, pontosPorGrafico - 1);
    faixas.putIfAbsent(indice, () => []).add(l);
  }

  final indices = faixas.keys.toList()..sort();
  return [for (final i in indices) _resumirFaixa(faixas[i]!, valorDe)];
}

PontoGrafico _resumirFaixa(
  List<LeituraHistorico> faixa,
  double Function(LeituraHistorico) valorDe,
) {
  final horarios = faixa.map((l) => l.horario).toList()..sort();
  final LeituraHistorico leituraMaxima = faixa.reduce(
    (a, b) => valorDe(b) > valorDe(a) ? b : a,
  );
  return PontoGrafico(
    horario: DateTime.fromMillisecondsSinceEpoch(
      horarios.map((t) => t.millisecondsSinceEpoch).reduce((a, b) => a + b) ~/
          faixa.length,
    ),
    primeira: horarios.first,
    ultima: horarios.last,
    media: faixa.map(valorDe).reduce((a, b) => a + b) / faixa.length,
    maximo: valorDe(leituraMaxima),
    horarioMaximo: leituraMaxima.horario,
    quantidade: faixa.length,
  );
}

class _GraficoHistorico extends StatelessWidget {
  const _GraficoHistorico({
    required this.titulo,
    required this.unidade,
    required this.limite,
    required this.eixoMin,
    required this.eixoMax,
    required this.inicio,
    required this.periodo,
    required this.pontos,
  });

  final String titulo;
  final String unidade;
  final double limite;
  final double eixoMin;
  final double eixoMax;
  final DateTime inicio;
  final PeriodoHistorico periodo;
  final List<PontoGrafico> pontos;

  // Usa o máximo da faixa, para um desvio curto não sumir na média.
  Color _corDoPonto(PontoGrafico ponto) =>
      ponto.maximo > limite ? corPerigo : corSegura;

  @override
  Widget build(BuildContext context) {
    final double maiorValor = pontos.map((p) => p.media).reduce(math.max);
    final double menorValor = pontos.map((p) => p.media).reduce(math.min);
    // Escala ampliada se necessário, em múltiplos de 10.
    final double eixoMaxReal =
        (math.max(eixoMax, maiorValor) / 10).ceil() * 10.0;
    final double eixoMinReal =
        (math.min(eixoMin, menorValor) / 10).floor() * 10.0;

    // Eixo X em minutos desde a meia-noite: rótulos em horários redondos.
    final DateTime meiaNoite = DateTime(inicio.year, inicio.month, inicio.day);
    double posicaoX(DateTime t) => t.difference(meiaNoite).inSeconds / 60;
    final double minX = posicaoX(inicio);
    final double maxX = posicaoX(inicio.add(periodo.duracao));
    final int intervalo = periodo.minutosEntreMarcacoes;

    return Column(
      children: [
        Text(titulo, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                clipData: const FlClipData.all(),
                minX: minX,
                maxX: maxX,
                minY: eixoMinReal,
                maxY: eixoMaxReal,
                gridData: const FlGridData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('Horário da medição'),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: intervalo.toDouble(),
                      getTitlesWidget: (value, meta) {
                        // Oculta os rótulos das bordas (horários quebrados).
                        final int minuto = value.round();
                        if ((value - minuto).abs() > 0.01 ||
                            minuto % intervalo != 0) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _horaMinuto(
                              meiaNoite.add(Duration(minutes: minuto)),
                            ),
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: limite,
                      color: Colors.grey,
                      strokeWidth: 1,
                      dashArray: [6, 4],
                    ),
                  ],
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: [
                      for (final p in pontos)
                        FlSpot(posicaoX(p.horario), p.media),
                    ],
                    isCurved: true,
                    preventCurveOverShooting: true,
                    color: Colors.black,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) =>
                          FlDotCirclePainter(
                            radius: 4,
                            color: _corDoPonto(pontos[index]),
                            strokeWidth: 0,
                          ),
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    maxContentWidth: 260,
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipColor: (spot) =>
                        _corDoPonto(pontos[spot.spotIndex]),
                    getTooltipItems: (spots) => [
                      for (final spot in spots)
                        LineTooltipItem(
                          _textoDoBalao(pontos[spot.spotIndex]),
                          const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  getTouchedSpotIndicator: (barData, spotIndexes) {
                    return spotIndexes.map((index) {
                      final Color cor = _corDoPonto(pontos[index]);
                      return TouchedSpotIndicatorData(
                        FlLine(color: cor, strokeWidth: 2),
                        FlDotData(
                          getDotPainter: (spot, percent, bar, idx) =>
                              FlDotCirclePainter(
                                radius: 6,
                                color: cor,
                                strokeWidth: 0,
                              ),
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _textoDoBalao(PontoGrafico p) {
    if (p.quantidade == 1) {
      return '${_diaMes(p.primeira)} às ${_horaCompleta(p.primeira)}\n'
          '${decimal(p.media)} $unidade';
    }
    return '${_diaMes(p.primeira)}, ${_horaCompleta(p.primeira)} '
        'a ${_horaCompleta(p.ultima)}\n'
        'Média ${decimal(p.media)} $unidade '
        '(${p.quantidade} leituras)\n'
        'Máx. ${decimal(p.maximo)} $unidade '
        'às ${_horaCompleta(p.horarioMaximo)}';
  }
}

// Texto do banner de leitura fora da faixa.
String textoAlerta({required bool temperatura, required bool umidade}) {
  final List<String> alterados = [
    if (temperatura) 'Temperatura',
    if (umidade) 'Umidade',
  ];
  return 'Atenção: ${alterados.join(' e ')} fora da faixa segura!';
}

class _AlertaPerigo extends StatelessWidget {
  const _AlertaPerigo({
    required this.temperaturaPerigo,
    required this.umidadePerigo,
  });

  final bool temperaturaPerigo;
  final bool umidadePerigo;

  @override
  Widget build(BuildContext context) {
    final String mensagem = textoAlerta(
      temperatura: temperaturaPerigo,
      umidade: umidadePerigo,
    );

    return Container(
      width: double.infinity,
      color: Colors.red,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              mensagem,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Adicionar o underline antes dessa classe serve para manter essa classe privada a esse arquivo .dart
class _MedidaCard extends StatelessWidget {
  const _MedidaCard({
    required this.label,
    required this.valorTexto,
    required this.perigo,
  });

  final String label;
  final String valorTexto;
  final bool perigo;

  @override
  Widget build(BuildContext context) {
    final Color cor = perigo ? corPerigo : corSegura;

    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 20)),
        Text(
          valorTexto,
          style: Theme.of(context).textTheme.headlineLarge
              ?.copyWith(color: cor, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
