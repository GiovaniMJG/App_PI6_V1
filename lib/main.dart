import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

// Opções do seletor de intervalo do histórico (por enquanto só na interface).
enum IntervaloHistorico {
  meiaHora('30 min'),
  umaHora('1 hora'),
  duasHoras('2 horas'),
  quatroHoras('4 horas');

  final String label;
  const IntervaloHistorico(this.label);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Estufa Monitor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const EstufaHomePage(),
    );
  }
}

// Era verde e vermelho, modificada por conta do daltonismo
const Color corPerigo = Colors.red;
const Color corSegura = Colors.blue;

// Limites para aletas. Mudar os valores conforme o ideal pela empresa.
const double temperaturaMin = 15.0;
const double temperaturaMax = 30.0;
const double umidadeMin = 40.0;
const double umidadeMax = 70.0;

const double temperaturaGraficoMin = -30.0;
const double temperaturaGraficoMax = 80.0;
const double umidadeGraficoMin = 0.0;
const double umidadeGraficoMax = 100.0;

class EstufaHomePage extends StatelessWidget {
  const EstufaHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final leituraRef =
        FirebaseFirestore.instance.collection('estufa').doc('leitura_atual');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitoramento da Estufa'),
      ),
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
          final double temperatura = dados['temperatura'] as double;
          final double umidade = dados['umidade'] as double;

          final bool temperaturaPerigo =
              temperatura < temperaturaMin || temperatura > temperaturaMax;
          final bool umidadePerigo =
              umidade < umidadeMin || umidade > umidadeMax;

          final bool emPerigo = temperaturaPerigo || umidadePerigo;

          return SingleChildScrollView(
            child: Column(
              children: [
                if (emPerigo)
                  _AlertaPerigo(
                    temperaturaPerigo: temperaturaPerigo,
                    umidadePerigo: umidadePerigo,
                  ),
                const SizedBox(height: 24),
                _MedidaCard(
                  label: 'Temperatura',
                  valorTexto: '${temperatura.toStringAsFixed(1)} °C',
                  perigo: temperaturaPerigo,
                ),
                const SizedBox(height: 32),
                _MedidaCard(
                  label: 'Umidade',
                  valorTexto: '${umidade.toStringAsFixed(1)} %',
                  perigo: umidadePerigo,
                ),
                const SizedBox(height: 32),
                const _GraficoHistorico(
                  campo: 'temperatura',
                  titulo: 'Histórico de Temperatura',
                  min: temperaturaMin,
                  max: temperaturaMax,
                  eixoMin: temperaturaGraficoMin,
                  eixoMax: temperaturaGraficoMax,
                ),
                const SizedBox(height: 32),
                const _GraficoHistorico(
                  campo: 'umidade',
                  titulo: 'Histórico de Umidade',
                  min: umidadeMin,
                  max: umidadeMax,
                  eixoMin: umidadeGraficoMin,
                  eixoMax: umidadeGraficoMax,
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GraficoHistorico extends StatefulWidget {
  const _GraficoHistorico({
    required this.campo,
    required this.titulo,
    required this.min,
    required this.max,
    required this.eixoMin,
    required this.eixoMax,
  });

  final String campo;
  final String titulo;
  final double min;
  final double max;
  final double eixoMin;
  final double eixoMax;

  @override
  State<_GraficoHistorico> createState() => _GraficoHistoricoState();
}

class _GraficoHistoricoState extends State<_GraficoHistorico> {
  IntervaloHistorico _intervalo = IntervaloHistorico.umaHora;

  @override
  Widget build(BuildContext context) {
    final String campo = widget.campo;
    final String titulo = widget.titulo;
    final double min = widget.min;
    final double max = widget.max;
    final double eixoMin = widget.eixoMin;
    final double eixoMax = widget.eixoMax;

    final historicoRef = FirebaseFirestore.instance
        .collection('estufa')
        .doc('leitura_atual')
        .collection('historico')
        .orderBy('timestamp', descending: true)
        .limit(10);

    return Column(
      children: [
        Text(titulo, style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Intervalo entre medições: '),
            DropdownButton<IntervaloHistorico>(
              value: _intervalo,
              items: [
                for (final opcao in IntervaloHistorico.values)
                  DropdownMenuItem(value: opcao, child: Text(opcao.label)),
              ],
              onChanged: (novoIntervalo) {
                if (novoIntervalo != null) {
                  setState(() => _intervalo = novoIntervalo);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 200,
            child: StreamBuilder<QuerySnapshot>(
              stream: historicoRef.snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                
                final List<double> valores = snapshot.data!.docs
                    .map((doc) => (doc.data() as Map<String, dynamic>)[campo] as double)
                    .toList()
                    .reversed
                    .toList();


                final double eixoMinReal = eixoMin < min ? eixoMin : min;
                final double eixoMaxReal = eixoMax > max ? eixoMax : max;

                Color corDoValor(double valor) =>
                    (valor < min || valor > max) ? corPerigo : corSegura;

                return LineChart(
                  LineChartData(
                    minY: eixoMinReal,
                    maxY: eixoMaxReal,
                    gridData: const FlGridData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 1,
                          getTitlesWidget: (value, meta) =>
                              Text(value.toInt().toString()),
                        ),
                      ),
                    ),
                    extraLinesData: ExtraLinesData(
                      horizontalLines: [
                        HorizontalLine(
                          y: min,
                          color: Colors.grey,
                          strokeWidth: 1,
                          dashArray: [6, 4],
                        ),
                        HorizontalLine(
                          y: max,
                          color: Colors.grey,
                          strokeWidth: 1,
                          dashArray: [6, 4],
                        ),
                      ],
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (int i = 0; i < valores.length; i++)
                            FlSpot(i.toDouble(), valores[i]),
                        ],
                        isCurved: true,
                        color: Colors.black,
                        dotData: FlDotData(
                          show: true,
                          getDotPainter: (spot, percent, barData, index) {
                            return FlDotCirclePainter(
                              radius: 4,
                              color: corDoValor(spot.y),
                              strokeWidth: 0,
                            );
                          },
                        ),
                      ),
                    ],
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipColor: (spot) => corDoValor(spot.y),
                      ),
                      getTouchedSpotIndicator: (barData, spotIndexes) {
                        return spotIndexes.map((index) {
                          final Color cor =
                              corDoValor(barData.spots[index].y);
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
                );
              },
            ),
          ),
        ),
      ],
    );
  }
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
    final List<String> alterados = [
      if (temperaturaPerigo) 'Temperatura',
      if (umidadePerigo) 'Umidade',
    ];
    final String mensagem =
        'Atenção: ${alterados.join(' e ')} fora da faixa segura!';

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
          style: Theme.of(context)
              .textTheme
              .headlineLarge
              ?.copyWith(color: cor, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
