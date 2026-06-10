const String modelViewerScript = '''
(() => {
    const CARPAINT_MATERIAL = 'roii';
    const TRANSLUCENT_MATERIALS = ['roii'];
    const CLAMP = (value, min, max) => Math.min(Math.max(value, min), max);
    const easeInOut = (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
    const redEmissive = [5, 0, 0];
    const blackEmissive = [0, 0, 0];

    const init = async () => {
        await customElements.whenDefined('model-viewer');
        const viewer = document.querySelector('#car');
        if (!viewer) return;

        // CSS 스타일
        const style = document.createElement('style');
        style.innerHTML = \`
            .label-hotspot {
                background: #fff; border-radius: 4px; border: none;
                box-shadow: 0 2px 4px rgba(0, 0, 0, 0.25);
                font-family: Futura, Helvetica Neue, sans-serif;
                padding: 0.5em 1em; position: absolute;
                text-wrap: nowrap; text-align: center;
                transform: translate3d(-50%, -50%, 0); cursor: pointer;
                display: none;
            }
        \`;
        document.head.appendChild(style);

        /* Label Hotspot 동적 생성 */
        window.createLabelHotspots = (hotspotsJson) => {
            const hotspots = JSON.parse(hotspotsJson);
            hotspots.forEach(h => {
                const hotspotHTML = \`
                    <button class="label-hotspot" 
                            slot="hotspot-\${h.slotName}"
                            data-position="\${h.position}"
                            data-normal="0m 0m 0m"
                            data-target="\${h.dataTarget}"
                            data-orbit="\${h.dataOrbit}">
                        \${h.label}
                    </button>
                \`;
                viewer.insertAdjacentHTML('beforeend', hotspotHTML);
            });

            // 클릭 이벤트 연결
            window.labelHotspotClickedFlag = false;
            const annotationClicked = (annotation) => {
                viewer.cameraTarget = annotation.dataset.target;
                viewer.cameraOrbit = annotation.dataset.orbit;
                window.labelHotspotClickedFlag = true;
            };

            viewer.querySelectorAll('.label-hotspot').forEach((hotspot) => {
                hotspot.addEventListener('click', () => annotationClicked(hotspot));
            });
        };

        window.toggleHotspots = (visible) => {
            const buttons = document.querySelectorAll('.label-hotspot');
            buttons.forEach(button => {
                button.style.display = visible ? 'block' : 'none';
            });
        };

        /* Error Hotspot 동적 생성 */
        window.createErrorHotspot = (targetId, severity, position, dataTarget, dataOrbit) => {
            const slotName = 'error-' + targetId;
            const existing = document.querySelector(\`[slot="hotspot-\${slotName}"]\`);
            if (existing) existing.remove();

            const severityColor = severity === 2 ? '#EF4444' : '#F59E0B';
            const hotspotHTML = \`
                <div slot="hotspot-\${slotName}" 
                     data-position="\${position}" 
                     data-normal="0m 0m 0m"
                     data-target="\${dataTarget}"
                     data-orbit="\${dataOrbit}"
                     style="width: 48px; height: 48px; background: white;
                            border-radius: 50%; box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                            display: flex; align-items: center; justify-content: center;
                            cursor: pointer; position: absolute;
                            transform: translate3d(-50%, -50%, 0);">
                    <div style="width: 36px; height: 36px; background: \${severityColor};
                                border-radius: 50%; display: flex;
                                align-items: center; justify-content: center;">
                        <span style="color: white; font-size: 24px; font-weight: bold;">!</span>
                    </div>
                </div>
            \`;
            viewer.insertAdjacentHTML('beforeend', hotspotHTML);
            
            const errorHotspot = document.querySelector(\`[slot="hotspot-\${slotName}"]\`);
            if (errorHotspot) {
                errorHotspot.addEventListener('click', () => {
                    viewer.cameraTarget = errorHotspot.dataset.target;
                    viewer.cameraOrbit = errorHotspot.dataset.orbit;
                    window.errorHotspotClicked = targetId;
                });
            }
        };

        window.removeErrorHotspot = (targetId) => {
            const slotName = 'error-' + targetId;
            const hotspot = document.querySelector(\`[slot="hotspot-\${slotName}"]\`);
            if (hotspot) hotspot.remove();
        };

        // 기존 코드 (viewer 설정, material 관리 등)
        viewer.setAttribute('shadow-intensity', '1.6');
        viewer.setAttribute('shadow-softness', '1');
        viewer.setAttribute('environment-image', 'legacy');
        viewer.setAttribute('max-camera-orbit', 'auto 65deg auto');

        const orbitPreset = [viewer.cameraOrbit ?? '45deg 65deg 100%', '180deg 0deg 70%'];
        const targetPreset = [viewer.cameraTarget ?? 'auto 8m auto', '0m auto -2m'];

        let index = 0;

        window.switchOrbit = () => {
            index = (index + 1) % orbitPreset.length;
            viewer.cameraOrbit = orbitPreset[index];
            viewer.cameraTarget = targetPreset[index];
        };

        // RGB 0-1 배열을 hex color string으로 변환
        const rgbToHex = (r, g, b) => {
            const toHex = (n) => Math.round(CLAMP(n, 0, 1) * 255).toString(16).padStart(2, '0');
            return '#' + toHex(r) + toHex(g) + toHex(b);
        };

        const findMaterialsByName = (model, names) => {
            const entries = [];
            names.forEach((name) => {
                const material = model.getMaterialByName?.(name) ?? model.materials?.find(m => m.name === name);
                if (!material) {
                    console.warn('[Alert] Material not found:', name);
                    return;
                }
                
                const pbr = material.pbrMetallicRoughness;
                const base = pbr && Array.isArray(pbr.baseColorFactor) ? [...pbr.baseColorFactor] : [1, 1, 1, 1];
                const originalAlpha = typeof base[3] === 'number' ? CLAMP(base[3], 0, 1) : 1;
                const baseHex = rgbToHex(base[0], base[1], base[2]);
                
                console.log('[Alert] Found material:', name, 'pbr:', !!pbr, 'base:', base);
                
                entries.push({ material, pbr, base, originalAlpha, baseHex });
            });
            return entries;
        };

        const applyAlpha = (entries, alphaFactor) => {
            entries.forEach((entry) => {
                if (!entry.pbr) return;  // pbr 없으면 스킵
                const updated = [...entry.base];
                updated[3] = CLAMP(entry.originalAlpha * alphaFactor, 0, 1);
                entry.pbr.setBaseColorFactor(updated);
            });
        };

        // 점멸 효과 적용 - emissive와 baseColor 둘 다 시도
        const applyAlertColor = (entries, progress) => {
            const redEmissiveColor = interpolateColor(blackEmissive, redEmissive, progress);
            // progress에 따라 원래색 → 빨강
            const redHex = progress > 0.5 ? '#EF4444' : null;
            
            entries.forEach((entry) => {
                // Emissive 시도
                try {
                    entry.material.setEmissiveFactor?.(redEmissiveColor);
                } catch (e) {}
                
                // BaseColor 시도 (pbr이 있으면)
                try {
                    if (entry.pbr?.setBaseColorFactor) {
                        const colorHex = redHex || entry.baseHex;
                        entry.pbr.setBaseColorFactor(colorHex);
                        console.log('[Alert] setBaseColorFactor:', colorHex);
                    }
                } catch (e) {
                    console.error('[Alert] BaseColor error:', e);
                }
            });
        };

        // 원래 색상으로 복원
        const resetAlertColor = (entries) => {
            entries.forEach((entry) => {
                // Emissive 초기화
                try {
                    entry.material.setEmissiveFactor?.(blackEmissive);
                } catch (e) {}
                
                // BaseColor 복원
                try {
                    if (entry.pbr?.setBaseColorFactor) {
                        entry.pbr.setBaseColorFactor(entry.baseHex);
                    }
                } catch (e) {}
            });
        };

        const setAlphaModeForEntries = (entries, mode) => {
            entries.forEach(({ material }) => {
                try { material.setAlphaMode?.(mode); } catch (e) { }
            });
        };

        const interpolateColor = (fromColor, toColor, progress) => {
            const r = fromColor[0] + (toColor[0] - fromColor[0]) * progress;
            const g = fromColor[1] + (toColor[1] - fromColor[1]) * progress;
            const b = fromColor[2] + (toColor[2] - fromColor[2]) * progress;
            return [r, g, b];
        };

        let trackedCarpaint = [];
        let trackedTranslucentParts = [];
        let trackedAlertParts = [];
        let isShowingParts = true;
        let isAlertActive = false;
        let animationFrame = 0;
        let alertAnimationFrame = 0;
        let alertStartTime = 0;

        const hydrateMaterials = () => {
            const model = viewer.model;
            if (!model) return;
            trackedCarpaint = findMaterialsByName(model, [CARPAINT_MATERIAL]);
            trackedTranslucentParts = findMaterialsByName(model, TRANSLUCENT_MATERIALS);
            applyAlpha(trackedCarpaint, 0.15);
            setAlphaModeForEntries(trackedCarpaint, 'BLEND');
            applyAlpha(trackedTranslucentParts, isShowingParts ? 0.15 : 0);
            setAlphaModeForEntries(trackedTranslucentParts, 'BLEND');
        };

        const runPartsAnimation = (targetVisible) => {
            const allParts = [...trackedCarpaint, ...trackedTranslucentParts];
            if (allParts.length === 0) return;
            cancelAnimationFrame(animationFrame);
            const start = performance.now();
            const initial = isShowingParts ? 0.15 : 0;
            const goal = targetVisible ? 0.15 : 0;
            if (initial === goal) return;
            setAlphaModeForEntries(trackedCarpaint, 'BLEND');
            const step = (now) => {
                const elapsed = now - start;
                const progress = CLAMP(elapsed / 400, 0, 1);
                const eased = easeInOut(progress);
                const currentFactor = initial + (goal - initial) * eased;
                applyAlpha(allParts, currentFactor);
                if (progress < 1) {
                    animationFrame = requestAnimationFrame(step);
                } else {
                    isShowingParts = targetVisible;
                    setAlphaModeForEntries(trackedCarpaint, 'BLEND');
                }
            };
            animationFrame = requestAnimationFrame(step);
        };

        const pulseAlert = (timestamp) => {
            if (!isAlertActive || trackedAlertParts.length === 0) return;
            
            try {
                if (alertStartTime === 0) alertStartTime = timestamp;
                const FADE_DURATION = 1000;
                const PAUSE_DURATION = 1000;
                const TOTAL_DURATION = PAUSE_DURATION + FADE_DURATION * 2;
                const elapsed = timestamp - alertStartTime;
                const cycleTime = elapsed % TOTAL_DURATION;
                let progress = 0;
                if (cycleTime < FADE_DURATION) {
                    progress = cycleTime / FADE_DURATION;
                } else if (cycleTime < FADE_DURATION * 2) {
                    progress = 1.0 - ((cycleTime - FADE_DURATION) / FADE_DURATION);
                }
                // emissive 또는 baseColor로 점멸
                applyAlertColor(trackedAlertParts, progress);
            } catch (e) {
                console.error('pulseAlert error:', e);
            }
            
            // 항상 다음 frame 예약 (에러가 나도 계속)
            alertAnimationFrame = requestAnimationFrame(pulseAlert);
        };

        // 여러 material을 동시에 점멸 지원 (추가/제거 방식)
        window.addAlertTarget = (materialName) => {
            const newParts = findMaterialsByName(viewer.model, [materialName]);
            // 중복 제거하며 추가
            newParts.forEach(newPart => {
                const exists = trackedAlertParts.some(p => p.material === newPart.material);
                if (!exists) {
                    trackedAlertParts.push(newPart);
                }
            });
            
            // 애니메이션이 실행 중이 아니면 시작
            if (!isAlertActive && trackedAlertParts.length > 0) {
                isAlertActive = true;
                alertStartTime = 0;
                alertAnimationFrame = requestAnimationFrame(pulseAlert);
            }
        };

        window.removeAlertTarget = (materialName) => {
            const partsToRemove = findMaterialsByName(viewer.model, [materialName]);
            partsToRemove.forEach(partToRemove => {
                const index = trackedAlertParts.findIndex(p => p.material === partToRemove.material);
                if (index !== -1) {
                    // 원래 색상으로 복원
                    resetAlertColor([trackedAlertParts[index]]);
                    trackedAlertParts.splice(index, 1);
                }
            });
            
            // 더 이상 점멸할 material이 없으면 중지
            if (trackedAlertParts.length === 0) {
                isAlertActive = false;
                cancelAnimationFrame(alertAnimationFrame);
            }
        };

        window.stopAlert = () => {
            isAlertActive = false;
            cancelAnimationFrame(alertAnimationFrame);
            if (trackedAlertParts.length > 0) {
                // 모든 material을 원래 색상으로 복원
                resetAlertColor(trackedAlertParts);
                trackedAlertParts = [];
            }
        };

        window.resetCamera = () => {
            viewer.cameraOrbit = '45deg 65deg 100%';
            viewer.cameraTarget = 'auto 8m auto';
        };

        viewer.addEventListener('load', hydrateMaterials);
        if (viewer.model) hydrateMaterials();

        window.toggleMaterials = () => runPartsAnimation(!isShowingParts);

        // JavaScript 준비 완료 플래그
        window.jsReady = true;
    };

    init();
})();
''';
