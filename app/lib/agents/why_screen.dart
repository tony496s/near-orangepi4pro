import 'package:flutter/widgets.dart';

import '../ui/theme.dart';
import 'console_app.dart';

/// One device in the comparison. [others]: whether it also drives agents on other machines (a laptop, a build server).
typedef WhyRow = ({
  String device,
  String runsOn,
  String lidClosed,
  String others,
  String isolated,
  String controls,
  String price,
});

/// The closing screen of the demo: every other agent gadget is a remote for a laptop that must stay open.
const whyRows = <WhyRow>[
  (
    device: 'Near',
    runsOn: 'Trong hộp',
    lidClosed: 'Vẫn chạy',
    others: 'Có',
    isolated: 'Có',
    controls: 'Màn chạm + giọng local',
    price: '~\$299',
  ),
  (
    device: 'Núm / Pro Harness',
    runsOn: 'Trên laptop',
    lidClosed: 'Dừng',
    others: 'Có',
    isolated: 'Không',
    controls: 'Núm, màn nhỏ',
    price: '\$129–299',
  ),
  (
    device: 'SlashVibe, MX Keypad',
    runsOn: 'Trên laptop',
    lidClosed: 'Dừng',
    others: 'Máy đang cắm',
    isolated: 'Không',
    controls: 'Phím tắt',
    price: '\$99–169',
  ),
  (
    device: 'Remote trên điện thoại',
    runsOn: 'Trên laptop',
    lidClosed: 'Dừng',
    others: 'Có',
    isolated: 'Không',
    controls: 'App, chạm từng lệnh',
    price: 'Miễn phí',
  ),
  (
    device: 'Mac mini',
    runsOn: 'Trong máy',
    lidClosed: 'Vẫn chạy',
    others: 'Không',
    isolated: 'Có',
    controls: 'Không có',
    price: '\$599',
  ),
];

/// Column widths; with the row padding they fill the ~1084 px right of the title.
const _cols = [228.0, 132.0, 116.0, 172.0, 92.0, 212.0, 92.0];

class WhyScreen extends StatelessWidget {
  const WhyScreen({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: const Key('why'),
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Container(
          color: const Color(0xFF071216),
          padding: const EdgeInsets.fromLTRB(36, 22, 36, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    eyebrowText('VÌ SAO LÀ NEAR', Ink.hot),
                    const SizedBox(height: 12),
                    Text('Gập laptop,\nđội agent vẫn chạy.', style: cs(29, weight: FontWeight.w500, height: 1.2)),
                    const SizedBox(height: 12),
                    Text('Mọi thiết bị khác chỉ là cái remote cho laptop đang mở.',
                        style: cs(16, color: Ink.dim, height: 1.35)),
                    const Spacer(),
                    Text('Chạm để quay lại', style: cs(13, color: Ink.faint)),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  children: [
                    _row(const ['', 'Agent chạy ở', 'Gập laptop', 'Điều khiển máy khác', 'Cách ly', 'Điều khiển', 'Giá'],
                        header: true),
                    for (final r in whyRows)
                      Expanded(
                        child: _row([r.device, r.runsOn, r.lidClosed, r.others, r.isolated, r.controls, r.price],
                            near: r.device == 'Near'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _row(List<String> cells, {bool header = false, bool near = false}) {
    Color colorOf(int i) {
      if (header) return Ink.dim;
      if (i == 0) return near ? Ink.hot : Ink.ink;
      final good = {'Trong hộp', 'Trong máy', 'Vẫn chạy', 'Có'}.contains(cells[i]);
      final bad = {'Trên laptop', 'Dừng', 'Không', 'Không có'}.contains(cells[i]);
      return good ? Ink.cool : (bad ? Ink.faint : Ink.ink);
    }

    return Container(
      height: header ? 30 : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: near ? const Color(0x1F86D8CC) : null,
        borderRadius: near ? BorderRadius.circular(12) : null,
        border: near || header ? null : const Border(top: BorderSide(color: Ink.hair)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            SizedBox(
              width: _cols[i],
              child: Text(
                cells[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: header
                    ? cs(13, weight: FontWeight.w600, color: colorOf(i), spacing: 1)
                    : cs(i == 0 ? 18 : 17, weight: i == 0 || near ? FontWeight.w600 : FontWeight.w400, color: colorOf(i)),
              ),
            ),
        ],
      ),
    );
  }
}
