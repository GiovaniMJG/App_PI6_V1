import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'main.dart' show corPerigo, corSegura, temperaturaMax, umidadeMax;

const List<String> _meses = [
  'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', //
  'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro',
];
const List<String> _diasSemana = [
  'seg',
  'ter',
  'qua',
  'qui',
  'sex',
  'sáb',
  'dom',
];

String _dois(int n) => n.toString().padLeft(2, '0');
String _chaveData(DateTime t) => '${t.year}-${_dois(t.month)}-${_dois(t.day)}';
String decimal(double valor, [int casas = 1]) =>
    valor.toStringAsFixed(casas).replaceAll('.', ',');

// Registro da manhã ou da tarde, no formato da ficha FOR 6.3.3.
class RegistroFicha {
  const RegistroFicha({
    required this.data,
    required this.periodo,
    required this.horario,
    required this.tempAtual,
    required this.tempMin,
    required this.tempMax,
    required this.umidAtual,
    required this.umidMin,
    required this.umidMax,
  });

  factory RegistroFicha.deMapa(Map<String, dynamic> d) => RegistroFicha(
    data: d['data'] as String,
    periodo: d['periodo'] as String,
    horario: (d['timestamp'] as Timestamp).toDate(),
    tempAtual: (d['tempAtual'] as num).toDouble(),
    tempMin: (d['tempMin'] as num).toDouble(),
    tempMax: (d['tempMax'] as num).toDouble(),
    umidAtual: (d['umidAtual'] as num).toDouble(),
    umidMin: (d['umidMin'] as num).toDouble(),
    umidMax: (d['umidMax'] as num).toDouble(),
  );

  final String data; // AAAA-MM-DD
  final String periodo; // manha ou tarde
  final DateTime horario;
  final double tempAtual, tempMin, tempMax;
  final double umidAtual, umidMin, umidMax;

  // Não conforme se a leitura ou a máxima do período passou do limite.
  bool get temperaturaFora =>
      tempAtual > temperaturaMax || tempMax > temperaturaMax;
  bool get umidadeFora => umidAtual > umidadeMax || umidMax > umidadeMax;
  bool get conforme => !temperaturaFora && !umidadeFora;
}

// Aba Registros: leituras de manhã e de tarde, mês a mês.
class RegistrosPage extends StatefulWidget {
  const RegistrosPage({super.key});

  @override
  State<RegistrosPage> createState() => _RegistrosPageState();
}

class _RegistrosPageState extends State<RegistrosPage> {
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  late Stream<QuerySnapshot> _consulta;

  @override
  void initState() {
    super.initState();
    _montarConsulta();
  }

  // Só os registros do mês escolhido (cerca de 60 leituras no Firestore).
  void _montarConsulta() {
    _consulta = FirebaseFirestore.instance
        .collection('estufa')
        .doc('leitura_atual')
        .collection('registros')
        .where('data', isGreaterThanOrEqualTo: _chaveData(_mes))
        .where(
          'data',
          isLessThan: _chaveData(DateTime(_mes.year, _mes.month + 1)),
        )
        .orderBy('data', descending: true)
        .snapshots();
  }

  void _mudarMes(int meses) {
    setState(() {
      _mes = DateTime(_mes.year, _mes.month + meses);
      _montarConsulta();
    });
  }

  @override
  Widget build(BuildContext context) {
    final DateTime hoje = DateTime.now();
    final bool mesAtual = _mes.year == hoje.year && _mes.month == hoje.month;

    return Scaffold(
      appBar: AppBar(title: const Text('Registros (FOR 6.3.3)')),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _mudarMes(-1),
              ),
              SizedBox(
                width: 180,
                child: Text(
                  '${_meses[_mes.month - 1]} de ${_mes.year}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: mesAtual ? null : () => _mudarMes(1),
              ),
            ],
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _consulta,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Erro: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final registros = [
                  for (final doc in snapshot.data!.docs)
                    RegistroFicha.deMapa(doc.data() as Map<String, dynamic>),
                ];
                if (registros.isEmpty) {
                  return const Center(
                    child: Text('Nenhum registro neste mês.'),
                  );
                }

                // Agrupa por dia; manhã antes da tarde.
                final porDia = <String, List<RegistroFicha>>{};
                for (final r in registros) {
                  porDia.putIfAbsent(r.data, () => []).add(r);
                }
                for (final lista in porDia.values) {
                  lista.sort((a, b) => a.horario.compareTo(b.horario));
                }
                final int naoConformes = registros
                    .where((r) => !r.conforme)
                    .length;

                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${registros.length} registros · '
                        '$naoConformes não conformes',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    for (final entrada in porDia.entries)
                      _CartaoDia(data: entrada.key, registros: entrada.value),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CartaoDia extends StatelessWidget {
  const _CartaoDia({required this.data, required this.registros});

  final String data;
  final List<RegistroFicha> registros;

  @override
  Widget build(BuildContext context) {
    final DateTime dia = DateTime.parse(data);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_dois(dia.day)}/${_dois(dia.month)} '
              '(${_diasSemana[dia.weekday - 1]})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            for (final r in registros) _LinhaRegistro(r),
          ],
        ),
      ),
    );
  }
}

class _LinhaRegistro extends StatelessWidget {
  const _LinhaRegistro(this.r);

  final RegistroFicha r;

  // Valor em vermelho se passou do limite.
  TextSpan _valor(String texto, bool fora) => TextSpan(
    text: texto,
    style: TextStyle(color: fora ? corPerigo : null),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text('${_dois(r.horario.hour)}:${_dois(r.horario.minute)}'),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      _valor(
                        '${decimal(r.tempAtual)} °C',
                        r.tempAtual > temperaturaMax,
                      ),
                      TextSpan(text: '  mín. ${decimal(r.tempMin)} · máx. '),
                      _valor(decimal(r.tempMax), r.tempMax > temperaturaMax),
                    ],
                  ),
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      _valor(
                        '${decimal(r.umidAtual, 0)} %',
                        r.umidAtual > umidadeMax,
                      ),
                      TextSpan(text: '  mín. ${decimal(r.umidMin, 0)} · máx. '),
                      _valor(decimal(r.umidMax, 0), r.umidMax > umidadeMax),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: r.conforme ? corSegura : corPerigo,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              r.conforme ? 'C' : 'NC',
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
