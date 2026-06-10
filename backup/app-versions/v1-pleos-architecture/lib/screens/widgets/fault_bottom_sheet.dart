import 'package:flutter/material.dart';
import '../../models/fault_data.dart';

class FaultBottomSheet extends StatefulWidget {
  final List<FaultData> faults;

  const FaultBottomSheet({super.key, required this.faults});

  @override
  State<FaultBottomSheet> createState() => _FaultBottomSheetState();
}

class _FaultBottomSheetState extends State<FaultBottomSheet> {
  int _currentIndex = 0;

  FaultData get _currentFault => widget.faults[_currentIndex];

  void _goToNextFault() {
    setState(() {
      _currentIndex = (_currentIndex + 1) % widget.faults.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Page indicator (outside sheet, on top)
        if (widget.faults.length > 1) _buildPageIndicator(),
        if (widget.faults.length > 1) const SizedBox(height: 12),
        // Bottom sheet
        Container(
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(32)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                height: 8,
                width: 72,
                decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              // Header with close button
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: 40,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(width: 48),
                    Text(
                      _currentFault.target,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      iconSize: 48,
                      color: Colors.black,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xfff5f5f5),
                        padding: const EdgeInsets.all(8),
                        shape: const CircleBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              // Fault Type & Severity badge
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.start,
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      Text(
                        _currentFault.faultType,
                        style: const TextStyle(
                          fontSize: 28,
                          color: Colors.black,
                        ),
                      ),
                      _buildSeverityBadge(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoSection('원인', _currentFault.cause),
                      const SizedBox(height: 20),
                      _buildInfoSection(
                        '대응 방안',
                        _currentFault.countermeasures
                            .map((c) => '• $c')
                            .join('\n'),
                      ),
                    ],
                  ),
                ),
              ),
              // Navigation button
              if (widget.faults.length > 1) _buildNavigationButton(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPageIndicator() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '${_currentIndex + 1} / ${widget.faults.length}',
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationButton() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 40),
      child: ElevatedButton(
        onPressed: _goToNextFault,
        style: ElevatedButton.styleFrom(
          backgroundColor: Color(0xff414656),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        child: const Text(
          '다음',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildSeverityBadge() {
    final color = _currentFault.severity == 2
        ? Color(0xffEF4444)
        : Color(0xffF59E0B);
    final text = _currentFault.severity == 2 ? 'Critical' : 'Warning';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color, width: 2),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 20,
        ),
      ),
    );
  }

  Widget _buildInfoSection(String title, String content) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 40),
      decoration: BoxDecoration(
        color: const Color(0xfff5f5f5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 24, color: Color(0xff585858)),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(
              fontSize: 28,
              height: 1.5,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}
