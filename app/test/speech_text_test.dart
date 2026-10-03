import 'package:dop_collect/assistant/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalize', () {
    test('folds case, punctuation and spacing', () {
      expect(SpeechText.normalize('  Ramesh,  se   500!  '), 'ramesh se 500');
    });

    test('converts Devanagari digits but keeps Devanagari letters', () {
      expect(SpeechText.normalize('रमेश से ५०० लिया'), 'रमेश से 500 लिया');
    });

    test('drops the rupee sign and joins a grouped figure', () {
      expect(SpeechText.normalize('₹1,000'), '1000');
      expect(SpeechText.normalize('₹1,50,000'), '150000');
    });
  });

  group('amountIn — digits', () {
    test('plain', () => expect(SpeechText.amountIn('ramesh se 500 liya'), 500));
    test('grouped', () => expect(SpeechText.amountIn('₹1,000 diya'), 1000));
    test('devanagari digits',
        () => expect(SpeechText.amountIn('रमेश से ५०० लिया'), 500));
    test('none', () => expect(SpeechText.amountIn('ramesh se liya'), isNull));
  });

  group('amountIn — spoken', () {
    // The gap that mattered: a spoken "paanch sau" returning null meant the
    // card silently offered his daily amount instead of the ₹500 in his hand.
    const cases = <String, int>{
      'paanch sau': 500,
      'panch sau liya': 500,
      'do sau': 200,
      'ek hazaar': 1000,
      'do hazaar': 2000,
      'das': 10,
      'pachas': 50,
      'bees rupaye': 20,
      'sau rupaye': 100,
      'hazaar': 1000,
      'dedh sau': 150,
      'dhai sau': 250,
      'sava sau': 125,
      'sadhe teen sau': 350,
      'paune sau': 75,
      'dedh hazaar': 1500,
      'five hundred': 500,
      'two thousand': 2000,
      // Devanagari
      'पांच सौ': 500,
      'दो हजार': 2000,
      'ढाई सौ': 250,
      'डेढ़ सौ': 150,
    };
    cases.forEach((phrase, expected) {
      test('"$phrase" is $expected',
          () => expect(SpeechText.amountIn(phrase), expected));
    });

    test('a name does not accumulate into the figure', () {
      // "do" is also the Hindi filler in "kar do" — it must not add 2.
      expect(SpeechText.amountIn('paanch sau ramesh se le liya kar do'), 500);
    });

    test('digits win over words when both appear', () {
      expect(SpeechText.amountIn('500 rupaye yani paanch sau'), 500);
    });
  });

  group('hasUnparsedNumber', () {
    test('a figure we understood is not unparsed', () {
      expect(SpeechText.hasUnparsedNumber('paanch sau liya'), isFalse);
      expect(SpeechText.hasUnparsedNumber('500 liya'), isFalse);
    });

    test('no number at all is not unparsed', () {
      expect(SpeechText.hasUnparsedNumber('ramesh se le liya'), isFalse);
    });
  });

  group('toLatin', () {
    const names = <String, String>{
      'रमेश': 'ramesh',
      'सुरेश': 'suresh',
      'सुनीता': 'sunita',
      'विजय': 'vijay',
      'कुमार': 'kumar',
      'यादव': 'yadav',
      'गीता': 'gita',
      'मोहन': 'mohan',
    };
    names.forEach((dev, latin) {
      test('$dev -> $latin', () => expect(SpeechText.toLatin(dev), latin));
    });

    test('latin passes through unchanged', () {
      expect(SpeechText.toLatin('Ramesh Kumar'), 'Ramesh Kumar');
    });
  });

  group('fold — spelling variants land on one key', () {
    for (final pair in const [
      ['Ramesh', 'Rameshh'],
      ['Sunita', 'Suneeta'],
      ['Vijay', 'Wijay'],
      ['Suresh', 'Sureesh'],
      ['Anil', 'Aneel'],
      ['रमेश', 'Ramesh'],
      ['सुनीता', 'Suneeta'],
    ]) {
      test('${pair[0]} == ${pair[1]}', () {
        expect(SpeechText.fold(pair[0]), SpeechText.fold(pair[1]));
      });
    }

    test('different people stay different', () {
      expect(SpeechText.fold('Sita'), isNot(SpeechText.fold('Gita')));
      expect(SpeechText.fold('Ramesh'), isNot(SpeechText.fold('Rakesh')));
    });
  });

  group('nameScore', () {
    test('an exact name scores highest', () {
      expect(SpeechText.nameScore('ramesh kumar', 'Ramesh Kumar'), 3);
    });

    test('a first name is a partial match, not an exact one', () {
      final partial = SpeechText.nameScore('ramesh', 'Ramesh Kumar');
      expect(partial, greaterThan(0));
      expect(partial, lessThan(3));
    });

    test('a Devanagari name matches the Latin book', () {
      expect(SpeechText.nameScore('रमेश कुमार', 'Ramesh Kumar'), 3);
    });

    test('one misheard letter in a long name still matches', () {
      expect(SpeechText.nameScore('ramesg kumar', 'Ramesh Kumar'),
          greaterThan(0));
    });

    test('a short name is held to a stricter standard', () {
      // Sita and Gita differ by one letter and are two different customers.
      expect(SpeechText.nameScore('sita', 'Gita Devi'), 0);
    });

    test('an unrelated name scores nothing', () {
      expect(SpeechText.nameScore('mahesh', 'Ramesh Kumar'), 0);
      expect(SpeechText.nameScore('ramesh', 'Suresh Yadav'), 0);
    });
  });
}
