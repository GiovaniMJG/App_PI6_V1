import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'comum.dart';

// Simula o ESP32 enviando leituras de temperatura/umidade ao Firestore (REST API).
final Uri historicoUrl = Uri.parse('$basePath/historico');

// Registros no formato da ficha FOR 6.3.3 (um documento por manhã/tarde).
const String caminhoRegistros =
    'projects/$projectId/databases/(default)/documents'
    '/estufa/leitura_atual/registros';
final Uri commitUrl = Uri.parse(
  'https://firestore.googleapis.com/v1/projects/$projectId'
  '/databases/(default)/documents:commit',
);

// Horários dos registros, como na ficha: (hora, minuto, período).
const List<(int, int, String)> horariosRegistro = [
  (7, 30, 'manha'),
  (16, 0, 'tarde'),
];

Random random = Random();

// Comportamento normal calibrado com a ficha FOR 6.3.3 (agosto/2026) por
// ml/calibrar_simulador.py: a sala esfria até o meio da manhã, esquenta até o
// fim da tarde e a umidade faz o caminho inverso.
const double temperaturaMinimaDia = 17.84;
const double subidaDia = 2.25;
const double variacaoTemperaturaDia = 0.78;
const double variacaoSubidaDia = 1.90;
const double horaMaisFria = 9.90;
const double horaPico = 17.69;
const double ruidoTemperatura = 0.086;
const double umidadeMaximaDia = 56.19;
const double quedaUmidadePorGrau = 2.25;
const double variacaoUmidadeDia = 1.50;
const double ruidoUmidade = 0.382;

// Probabilidade de desvio por leitura (~1 por hora). Não vem da ficha:
// escolhida para haver eventos suficientes na avaliação do modelo.
const double chanceDesvio = 0.004;

// Desvios simulados; leituras afetadas são marcadas (desvioSimulado),
// servindo de gabarito para avaliar o modelo de ML.
enum TipoDesvio {
  portaAberta(leituras: 6, passoTemperatura: 0.5, passoUmidade: 2.0),
  falhaRefrigeracao(leituras: 20, passoTemperatura: 0.25, passoUmidade: 0.3),
  picoSensor(leituras: 1, passoTemperatura: 0, passoUmidade: 0),
  // Só pelo teclado (demonstração); fora do sorteio, não altera os dados do ML.
  umidadeAlta(leituras: 8, passoTemperatura: 0, passoUmidade: 1.5);

  final int leituras;
  final double passoTemperatura;
  final double passoUmidade;
  const TipoDesvio({
    required this.leituras,
    required this.passoTemperatura,
    required this.passoUmidade,
  });
}

const List<TipoDesvio> desviosSorteados = [
  TipoDesvio.portaAberta,
  TipoDesvio.falhaRefrigeracao,
  TipoDesvio.picoSensor,
];

double arredonda(double valor) =>
    (valor * 10).round() / 10; // resolução do DHT22

// Valor aleatório em [-amplitude, +amplitude].
double ruido(double amplitude) => (random.nextDouble() * 2 - 1) * amplitude;

// Valor aleatório com distribuição normal padrão (Box-Muller).
double normal() =>
    sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());

// Formato do ciclo diário: 0 na hora mais fria, 1 no pico.
double formaDiaria(double hora) {
  const double subida = (horaPico - horaMaisFria) % 24;
  final double u = (hora - horaMaisFria) % 24;
  return u < subida
      ? (1 - cos(pi * u / subida)) / 2
      : (1 + cos(pi * (u - subida) / (24 - subida))) / 2;
}

// Variação sorteada para cada dia (temperatura mínima, subida e umidade).
class SorteioDia {
  SorteioDia() : base = normal(), subida = normal(), umidade = normal();

  final double base;
  final double subida;
  final double umidade;
}

class Leitura {
  const Leitura(this.temperatura, this.umidade, this.emDesvio, this.tipo);

  final double temperatura;
  final double umidade;
  final bool emDesvio;
  final String tipo;
}

// Estado do sensor simulado; gera uma leitura por chamada.
class SensorSimulado {
  double? _temperatura;
  double? _umidade;

  DateTime? _dia;
  SorteioDia _hoje = SorteioDia();
  SorteioDia _amanha = SorteioDia();

  // Acréscimo do desvio em andamento.
  double _extraTemperatura = 0;
  double _extraUmidade = 0;

  TipoDesvio? _desvioAtual;
  int _leiturasRestantes = 0;

  bool desviosAleatorios = true;

  // Desvio pedido pelo teclado; aplicado quando não há outro em andamento.
  TipoDesvio? desvioPedido;

  void _avancarDia(DateTime horario) {
    final dia = DateTime(horario.year, horario.month, horario.day);
    _dia ??= dia;
    while (_dia!.isBefore(dia)) {
      _hoje = _amanha;
      _amanha = SorteioDia();
      _dia = DateTime(_dia!.year, _dia!.month, _dia!.day + 1);
    }
  }

  Leitura proxima(DateTime horario) {
    _avancarDia(horario);

    // Curva normal do horário, com a variação do dia interpolada.
    final double hora =
        horario.hour + horario.minute / 60 + horario.second / 3600;
    final double frac = hora / 24;
    double interpola(double a, double b) => a + (b - a) * frac;
    final double forma = formaDiaria(hora);
    final double subida =
        max(
          0.0,
          subidaDia +
              variacaoSubidaDia * interpola(_hoje.subida, _amanha.subida),
        ) *
        forma;
    final double alvoTemperatura =
        temperaturaMinimaDia +
        variacaoTemperaturaDia * interpola(_hoje.base, _amanha.base) +
        subida;
    final double alvoUmidade =
        umidadeMaximaDia +
        variacaoUmidadeDia * interpola(_hoje.umidade, _amanha.umidade) -
        quedaUmidadePorGrau * subidaDia * forma;

    // Oscilação em torno da curva, com retorno gradual a ela.
    double temperatura = _temperatura ?? alvoTemperatura;
    double umidade = _umidade ?? alvoUmidade;
    temperatura +=
        (alvoTemperatura - temperatura) * 0.1 + ruido(ruidoTemperatura);
    umidade += (alvoUmidade - umidade) * 0.1 + ruido(ruidoUmidade);
    _temperatura = temperatura;
    _umidade = umidade;

    // Início de desvio (pedido ou sorteio).
    if (_desvioAtual == null && _extraTemperatura.abs() < 0.3) {
      if (desvioPedido != null) {
        _desvioAtual = desvioPedido;
        desvioPedido = null;
      } else if (desviosAleatorios && random.nextDouble() < chanceDesvio) {
        _desvioAtual =
            desviosSorteados[random.nextInt(desviosSorteados.length)];
      }
      _leiturasRestantes = _desvioAtual?.leituras ?? 0;
    }

    // Efeito do desvio.
    double pico = 0;
    final desvio = _desvioAtual;
    if (desvio != null) {
      if (desvio == TipoDesvio.picoSensor) {
        // Leitura isolada errada; para baixo fica dentro da faixa.
        pico = (random.nextBool() ? 1 : -1) * (2.5 + random.nextDouble());
      } else {
        _extraTemperatura += desvio.passoTemperatura;
        _extraUmidade += desvio.passoUmidade;
      }
      _leiturasRestantes--;
    } else {
      // Retorno gradual ao normal.
      _extraTemperatura *= 0.6;
      _extraUmidade *= 0.6;
    }

    final bool emDesvio =
        desvio != null ||
        _extraTemperatura.abs() > 0.5 ||
        _extraUmidade.abs() > 2;
    final String tipo = desvio?.name ?? (emDesvio ? 'recuperacao' : '');

    if (_leiturasRestantes <= 0) _desvioAtual = null;

    return Leitura(
      arredonda((temperatura + _extraTemperatura + pico).clamp(-40.0, 80.0)),
      arredonda((umidade + _extraUmidade).clamp(0.0, 100.0)),
      emDesvio,
      tipo,
    );
  }
}

// Gera leituras em CSV a partir de 03/08/2026 (segunda-feira, mês da ficha
// FOR 6.3.3), sem acessar o Firebase.
void gerarCsv(int quantidade, String caminho, {bool comDesvios = true}) {
  final sensor = SensorSimulado()..desviosAleatorios = comDesvios;
  final inicio = DateTime(2026, 8, 3);
  final saida = StringBuffer(
    'timestamp,temperatura,umidade,desvioSimulado,tipoDesvio\n',
  );
  for (int i = 0; i < quantidade; i++) {
    final horario = inicio.add(Duration(seconds: 15 * i));
    final l = sensor.proxima(horario);
    saida.writeln(
      '${horario.toUtc().toIso8601String()},${l.temperatura},${l.umidade},'
      '${l.emDesvio ? 1 : 0},${l.tipo}',
    );
  }
  File(caminho)
    ..createSync(recursive: true)
    ..writeAsStringSync(saida.toString());
  print('$quantidade leituras gravadas em $caminho');
}

// Mínima e máxima desde o último registro, como o termohigrômetro da ficha.
class Acumulador {
  double? tempMin, tempMax, umidMin, umidMax;

  void adicionar(Leitura l) {
    tempMin = min(tempMin ?? l.temperatura, l.temperatura);
    tempMax = max(tempMax ?? l.temperatura, l.temperatura);
    umidMin = min(umidMin ?? l.umidade, l.umidade);
    umidMax = max(umidMax ?? l.umidade, l.umidade);
  }

  void zerar() => tempMin = tempMax = umidMin = umidMax = null;
}

// Próximo horário de registro depois de [depois].
(DateTime, String) proximoRegistro(DateTime depois) {
  for (int dia = 0; dia < 2; dia++) {
    for (final (hora, minuto, periodo) in horariosRegistro) {
      final t = DateTime(
        depois.year,
        depois.month,
        depois.day + dia,
        hora,
        minuto,
      );
      if (t.isAfter(depois)) return (t, periodo);
    }
  }
  throw StateError('Nenhum horário de registro configurado.');
}

String _dois(int n) => n.toString().padLeft(2, '0');
String chaveData(DateTime t) => '${t.year}-${_dois(t.month)}-${_dois(t.day)}';

// Documento do registro; o id (data_período) evita duplicar o mesmo registro.
Map<String, dynamic> documentoRegistro(
  DateTime horario,
  String periodo,
  Leitura atual,
  Acumulador acumulado,
  String origem,
) => {
  'name': '$caminhoRegistros/${chaveData(horario)}_$periodo',
  'fields': {
    'data': {'stringValue': chaveData(horario)},
    'periodo': {'stringValue': periodo},
    'timestamp': {'timestampValue': horario.toUtc().toIso8601String()},
    'tempAtual': {'doubleValue': atual.temperatura},
    'tempMin': {'doubleValue': acumulado.tempMin},
    'tempMax': {'doubleValue': acumulado.tempMax},
    'umidAtual': {'doubleValue': atual.umidade},
    'umidMin': {'doubleValue': acumulado.umidMin},
    'umidMax': {'doubleValue': acumulado.umidMax},
    'origem': {'stringValue': origem},
  },
};

// Grava documentos de uma vez (até 500 por requisição).
Future<void> gravarDocumentos(List<Map<String, dynamic>> documentos) async {
  for (int i = 0; i < documentos.length; i += 500) {
    final lote = documentos.sublist(i, min(i + 500, documentos.length));
    final resposta = await http.post(
      commitUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'writes': [
          for (final d in lote) {'update': d},
        ],
      }),
    );
    if (resposta.statusCode != 200) {
      throw HttpException('Erro ${resposta.statusCode}: ${resposta.body}');
    }
  }
}

// Registros de 03/08/2026 até agora com o modelo calibrado (sem desvios),
// para a aba Registros já ter meses de dados.
Future<void> gerarRegistrosRetroativos() async {
  random = Random(1);
  final sensor = SensorSimulado()..desviosAleatorios = false;
  final acumulado = Acumulador();
  final fim = DateTime.now();
  DateTime horario = DateTime(2026, 8, 3);
  (DateTime, String) proximo = proximoRegistro(horario);
  final documentos = <Map<String, dynamic>>[];

  while (!proximo.$1.isAfter(fim)) {
    final leitura = sensor.proxima(horario);
    acumulado.adicionar(leitura);
    if (!horario.isBefore(proximo.$1)) {
      documentos.add(
        documentoRegistro(
          horario,
          proximo.$2,
          leitura,
          acumulado,
          'retroativo',
        ),
      );
      acumulado.zerar();
      proximo = proximoRegistro(horario);
    }
    horario = horario.add(const Duration(seconds: 15));
  }

  await gravarDocumentos(documentos);
  print('${documentos.length} registros retroativos gravados.');
}

// Valor depois de uma opção da linha de comando (ex.: --seed 3).
String? valorDe(List<String> args, String opcao) {
  final int i = args.indexOf(opcao);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  // Modo CSV: dart run bin/simulador_esp32.dart --csv 40320 [--seed 1]
  //   [--sem-desvios] [--saida caminho] [--repeticoes 10]
  if (args.contains('--csv')) {
    final int quantidade = int.tryParse(valorDe(args, '--csv') ?? '') ?? 40320;
    final int semente = int.tryParse(valorDe(args, '--seed') ?? '') ?? 1;
    final int repeticoes =
        int.tryParse(valorDe(args, '--repeticoes') ?? '') ?? 0;
    final bool comDesvios = !args.contains('--sem-desvios');
    if (repeticoes > 0) {
      for (int r = 0; r < repeticoes; r++) {
        random = Random(semente + r);
        final nome = (semente + r).toString().padLeft(2, '0');
        gerarCsv(
          quantidade,
          'ml/repeticoes/dados_$nome.csv',
          comDesvios: comDesvios,
        );
      }
    } else {
      random = Random(semente);
      gerarCsv(
        quantidade,
        valorDe(args, '--saida') ?? 'ml/dados_simulados.csv',
        comDesvios: comDesvios,
      );
    }
    return;
  }

  // Preenche a aba Registros desde 03/08/2026 (uma vez só).
  if (args.contains('--registros-retroativos')) {
    await gerarRegistrosRetroativos();
    return;
  }

  final http.Client? clientePush = await criarClientePush();
  final sensor = SensorSimulado();
  final acumulado = Acumulador();
  (DateTime, String) proximo = proximoRegistro(DateTime.now());

  final monitor = MonitorAlertas();

  // Desvio manual pelo teclado: p, f, s ou u + Enter.
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((linha) {
    sensor.desvioPedido = switch (linha.trim().toLowerCase()) {
      'p' => TipoDesvio.portaAberta,
      'f' => TipoDesvio.falhaRefrigeracao,
      's' => TipoDesvio.picoSensor,
      'u' => TipoDesvio.umidadeAlta,
      _ => null,
    };
  });

  print('Simulador ESP32 iniciado. Ctrl+C para parar.');
  print(
    'Provocar desvio: p = porta aberta, f = falha na refrigeração, '
    's = pico do sensor, u = umidade alta (digite e aperte Enter).',
  );

  while (true) {
    final leitura = sensor.proxima(DateTime.now());

    // Registro da manhã ou da tarde, com mínima e máxima desde o anterior.
    acumulado.adicionar(leitura);
    final DateTime horarioLocal = DateTime.now();
    if (!horarioLocal.isBefore(proximo.$1)) {
      try {
        await gravarDocumentos([
          documentoRegistro(
            horarioLocal,
            proximo.$2,
            leitura,
            acumulado,
            'simulador',
          ),
        ]);
        print('  -> Registro da ${proximo.$2} gravado.');
        acumulado.zerar();
        proximo = proximoRegistro(horarioLocal);
      } catch (erro) {
        print('  -> Falha ao gravar o registro, tentando de novo: $erro');
      }
    }

    final agora = DateTime.now().toUtc().toIso8601String();
    final campos = {
      'temperatura': {'doubleValue': leitura.temperatura},
      'umidade': {'doubleValue': leitura.umidade},
      'timestamp': {'timestampValue': agora},
      'desvioSimulado': {'booleanValue': leitura.emDesvio},
      'tipoDesvio': {'stringValue': leitura.tipo},
      'versaoSimulador': {'integerValue': '2'},
    };

    try {
      final respostaAtual = await http.patch(
        leituraAtualUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fields': campos}),
      );

      final respostaHistorico = await http.post(
        historicoUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fields': campos}),
      );

      if (respostaAtual.statusCode == 200 &&
          respostaHistorico.statusCode == 200) {
        print(
          'Enviado: temperatura=${leitura.temperatura.toStringAsFixed(1)}°C '
          'umidade=${leitura.umidade.toStringAsFixed(1)}%'
          '${leitura.emDesvio ? '  [desvio: ${leitura.tipo}]' : ''}',
        );

        final alerta = monitor.avaliar(leitura.temperatura, leitura.umidade);
        if (alerta != null && clientePush != null) {
          await enviarPush(clientePush, alerta.$1, alerta.$2);
        }
      } else {
        print(
          'Erro atual=${respostaAtual.statusCode} '
          'historico=${respostaHistorico.statusCode}',
        );
      }
    } catch (erro) {
      print('Falha de conexão, tentando de novo na próxima leitura: $erro');
    }

    // 15 s: 11.520 gravações/dia, abaixo da cota gratuita (20.000).
    await Future.delayed(const Duration(seconds: 15));
  }
}
