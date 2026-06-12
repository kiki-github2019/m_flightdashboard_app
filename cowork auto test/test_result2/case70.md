# Case 70: G-LAYOUT-20 info hide before board off → forced visible

- **그룹**: G-LAYOUT
- **검증 대상**: combo: info hide + board off forces info
- **기대 결과**: v3-audit B: source single-board analysis
- **관측 결과**: `FAIL`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case70_step01.png) |
| 02 | flight1 info off | ![](case70_step02.png) |

## Failure Detail
```
step 2 (flight1 info off): board 1 info/plot column hidden after board-on restore
State snapshot: BoardOff actual=[false false] expected=[false false]; F1{off=0,panel=1,idx=1,time=0.000,spin=0.000,tabs=1/1,plots=0/0,selPlots=0/0,colsHidden=[1 0 1],summary=0,boPlots=0,boMarkers=0,video=[sync=0 frame=1/46525]}; F2{off=0,panel=1,idx=1,time=0.000,spin=0.000,tabs=1/1,plots=0/0,selPlots=0/0,colsHidden=[0 0 0],summary=0,boPlots=0,boMarkers=0,video=[sync=0 frame=1/165205]}
```
