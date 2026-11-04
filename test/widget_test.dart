import 'package:estufa_app/main.dart';
import 'package:estufa_app/registros.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Registros (FOR 6.3.3)', () {
    RegistroFicha registro({double tempMax = 19.5, double umidMax = 57}) =>
        RegistroFicha(
          data: '2026-11-03',
          periodo: 'tarde',
          horario: DateTime(2026, 11, 3, 16),
          tempAtual: 19.0,
          tempMin: 17.5,
          tempMax: tempMax,
          umidAtual: 52,
          umidMin: 50,
          umidMax: umidMax,
        );

    test('dentro dos limites é conforme', () {
      expect(registro().conforme, isTrue);
    });

    test('máxima acima de 20 °C no período é não conforme', () {
      expect(registro(tempMax: 20.6).conforme, isFalse);
    });

    test('número com vírgula', () {
      expect(decimal(19.75), '19,8');
      expect(decimal(57, 0), '57');
    });
  });

  group('Texto do alerta', () {
    test('só temperatura', () {
      expect(
        textoAlerta(temperatura: true, umidade: false),
        'Atenção: Temperatura fora da faixa segura!',
      );
    });

    test('temperatura e umidade', () {
      expect(
        textoAlerta(temperatura: true, umidade: true),
        'Atenção: Temperatura e Umidade fora da faixa segura!',
      );
    });
  });

  group('Agrupamento do histórico', () {
    final DateTime inicio = DateTime(2026, 10, 30, 10);
    const Duration umaHora = Duration(hours: 1);

    test('1 h de leituras a cada 15 s vira 30 pontos de 8 leituras', () {
      final leituras = [
        for (int i = 0; i < 240; i++)
          LeituraHistorico(inicio.add(Duration(seconds: 15 * i)), 18, 50),
      ];
      final pontos = agruparLeituras(
        leituras,
        inicio,
        umaHora,
        (l) => l.temperatura,
      );
      expect(pontos.length, pontosPorGrafico);
      expect(pontos.every((p) => p.quantidade == 8), isTrue);
    });

    test('ponto guarda média e máximo da faixa', () {
      final leituras = [
        LeituraHistorico(inicio, 18, 50),
        LeituraHistorico(inicio.add(const Duration(seconds: 30)), 22, 50),
      ];
      final pontos = agruparLeituras(
        leituras,
        inicio,
        umaHora,
        (l) => l.temperatura,
      );
      expect(pontos.single.media, 20);
      expect(pontos.single.maximo, 22);
      expect(pontos.single.primeira, inicio);
      expect(pontos.single.ultima, inicio.add(const Duration(seconds: 30)));
      expect(
        pontos.single.horarioMaximo,
        inicio.add(const Duration(seconds: 30)),
      );
      // A média fica no limite, mas o máximo passa: o ponto fica vermelho.
      expect(pontos.single.maximo > temperaturaMax, isTrue);
    });

    test('leitura no fim da janela entra no último ponto', () {
      final pontos = agruparLeituras(
        [LeituraHistorico(inicio.add(umaHora), 19, 50)],
        inicio,
        umaHora,
        (l) => l.temperatura,
      );
      expect(pontos.single.quantidade, 1);
    });
  });
}
