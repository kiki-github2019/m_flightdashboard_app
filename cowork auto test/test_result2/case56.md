# Case 56: G-LAYOUT-06 info/dataView toggle

- **그룹**: G-LAYOUT
- **검증 대상**: info/dataView toggles
- **기대 결과**: user-facing buttons drive PanelVisible
- **관측 결과**: `FAIL`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case56_step01.png) |
| 02 | Flight 1 info off | ![](case56_step02.png) |

## Failure Detail
```
step 2 (Flight 1 info off): board 1 info/plot column hidden after board-on restore
State snapshot: BoardOff actual=[false false] expected=[false false]; F1{off=0,panel=1,idx=1,time=0.000,spin=0.000,tabs=1/1,plots=0/0,selPlots=0/0,colsHidden=[1 0 1],summary=0,boPlots=0,boMarkers=0,video=[sync=0 frame=1/46525]}; F2{off=0,panel=1,idx=1,time=0.000,spin=0.000,tabs=1/1,plots=0/0,selPlots=0/0,colsHidden=[0 0 0],summary=0,boPlots=0,boMarkers=0,video=[sync=0 frame=1/165205]}
```
