#include "stdlib.h"
#include "math.h"
#include "wiring.h"
#include "WProgram.h"
#include "Wire.h"

#include <sd_raw.h>
#include <sd_raw_config.h>
#include <sd_reader_config.h>

#include <sdlog.h>

#define DEBUG

#include "Smoothing.h"
#include "Timer.h"
#include "hCommands.h"
#include "hHardware.h"

#define MAXCMDS 3
/*
Command commands[MAXCMDS] = {
  {HACTION_FWD,   2000},
  {HACTION_REV,   2000},
};
*/
Command commands[MAXCMDS] = {
  {HACTION_TAKEOFF,    0},      //climb until we're 60cm
  {HACTION_HOVER, 4000},   //hover for 5 seconds
//  {HACTION_FWD,   2000},
//  {HACTION_HOVER, 500},   //hover for 5 seconds
//  {HACTION_REV,   2000},
  {HACTION_LAND,  0}, //descend until 10cm
};


boolean txActive = false;

Timer hActionTimer;
Timer logSyncTimer;
#define LOGSYNCRATE 1000

Timer bottomRangeTimer;
int bottomRange = 0;
int desiredBottomRange = 0;
boolean bottomRangeLocked = false;
//Timer bottomRangeLockTimer;

Timer incMotorRateLimit;
Timer decMotorRateLimit;
#define DECRATE 1000
#define INCRATE 500

/******************************************************************** setup() */
void setup(){
  Serial.begin(9600);

  int sdinit = sd_raw_init();
  if(sdinit != 1){
     Serial.print("MMC/SD initialization failed: ");
     Serial.println(sdinit);
  }
  logger("starting logging...");
  
  for(int i=0;i<MAXCMDS;i++){
    char buf[256]; logger( dumpCommand(&commands[i], buf) );
  }

  hHWsetup();
  

  newSmoothed(&txActiveSmooth);
  newTimer(&txActiveTimer, 150);

  disableTimer(&hActionTimer);
  
  newTimer(&bottomRangeTimer, 200);
  //newTimer(&bottomRangeLockTimer, 1000);

  newTimer(&decMotorRateLimit, DECRATE);
  newTimer(&incMotorRateLimit, INCRATE);

  newTimer(&logSyncTimer, LOGSYNCRATE);

  logger("setup complete");
  sd_raw_sync();
}



Command hAction = {HACTION_OFF, 0};
int iAction = 0;
/******************************************************************** loop() */
void loop(){
  //get bottom range
  if( checkTimer(&bottomRangeTimer) ){
    //Serial.print("bottomRange: ");
    //Serial.println(bottomRange);
    loggerInt("btmRange", bottomRange);
    bottomRange = readRange(srfAddress);
    requestRange(srfAddress);
  }
  
  
  if(bottomRangeLocked){
    if(bottomRange  < desiredBottomRange){
      if( checkTimer(&incMotorRateLimit) ){
        logger("IncMotors()");
        IncMotors();
      }
    } else
    if(bottomRange > desiredBottomRange){
      if( checkTimer(&decMotorRateLimit) ){
        logger("DecMotors()");
        DecMotors();
      }
    }    
  }
  
  
/*  
  //check txLED
  if( checkTimer(&txActiveTimer) ){
    txActive = isTxActive(&txActiveSmooth, heliLedPin);
    
    if(txActive){
      Serial.println("txActive");
      
      hAction.cmd = HACTION_OFF;
      start = true;
      iAction = 0;
      if(!off){
        disableTimer(&hActionTimer);
      }
    }
    
  }
*/

  switch(hAction.cmd){
    case HACTION_OFF:{ //on the ground - rotors idle
      
      //Serial.println("HACTION_OFF");

      if(isTimerDisabled(&hActionTimer)){
        logger("wait");  
        iAction = 0;
        newTimer(&hActionTimer, 10000);
        
        StopMotors();
        bottomRangeLocked = false;
        rotorStop();
        
        disableTimer(&bottomRangeTimer); //switch off ranger
      }
      if( checkTimer(&hActionTimer) ){
        logger("go");

        disableTimer(&hActionTimer);
        enableTimer(&bottomRangeTimer); //switch ranger on
        
        newTimer(&decMotorRateLimit, DECRATE); //reset to defaults
        newTimer(&incMotorRateLimit, INCRATE);
        
        hAction.cmd = HACTION_NEXT;
      }
      
      //hAction.cmd = HACTION_NEXT;
    }
    break;
    /*
    case HACTION_UP:{ //moving upwards
      //Serial.println("HACTION_UP");
      if(isTimerDisabled(&hActionTimer)){
        newTimer(&hActionTimer, 150);
      }
      
      //fake height here
      //int h = M1Speed;
      //if( h < hAction.value ){
        
      if( bottomRange < hAction.value ){
        if( checkTimer(&hActionTimer) ){
          IncMotors();
        }
      }else{
        hAction.cmd = HACTION_NEXT;
        disableTimer(&hActionTimer);
      }
    }
    break;
    
    case HACTION_DOWN:{ //moving downwards
      //Serial.println("HACTION_DOWN");
      if(isTimerDisabled(&hActionTimer)){
        newTimer(&hActionTimer, 500);
      }
      
      //fake height here
      //int h = M1Speed;
      //if( h > hAction.value ){
        
      if( bottomRange > hAction.value ){
        if( checkTimer(&hActionTimer) ){
          DecMotors();
        }
      }else{
        hAction.cmd = HACTION_NEXT;
        disableTimer(&hActionTimer);
      }
    }
    break;
    */
    case HACTION_HOVER:{ //hovering for x ms
      //Serial.println("HACTION_HOVER");
      if(isTimerDisabled(&hActionTimer)){
        newTimer(&hActionTimer, hAction.value);        
      }
      if( checkTimer(&hActionTimer) ){        
        disableTimer(&hActionTimer);
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;

    case HACTION_FWD:{ // forward for x ms
      //Serial.println("HACTION_FWD");
      if(isTimerDisabled(&hActionTimer)){
        newTimer(&hActionTimer, hAction.value);
        
        rotorFwd();
      }
      if( checkTimer(&hActionTimer) ){
        rotorStop();
        
        disableTimer(&hActionTimer);
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;

    case HACTION_REV:{ // reverse for x ms
      //Serial.println("HACTION_REV");
      if(isTimerDisabled(&hActionTimer)){
        newTimer(&hActionTimer, hAction.value);
        
        rotorRev();
      }
      if( checkTimer(&hActionTimer) ){
        rotorStop();
        
        disableTimer(&hActionTimer);
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;
    
    case HACTION_BTMRANGE:{ //set desired bottom range
      bottomRangeLocked = true;
      desiredBottomRange = hAction.value;
      if(bottomRange == desiredBottomRange){
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;

    case HACTION_TAKEOFF:{
      //we want to ascend to 30 at 50, then from 30 -> 50 at 150
      // in an attempt to deal with the ground effect
      const int TAKEOFF_POINT = 50;
      const int GNDFX_POINT = 30;
      
      bottomRangeLocked = true;
      desiredBottomRange = TAKEOFF_POINT;
      
      if(bottomRange < GNDFX_POINT){
        //Serial.println("GND_POINT!");
        incMotorRateLimit.delayTime = 100;
      }else{
        incMotorRateLimit.delayTime = INCRATE;
      }
      
      
      if(bottomRange >= desiredBottomRange){
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;

    case HACTION_LAND:{
      //we want to descend to 30 at 1500, then from 30 -> 10 at 300
      // in an attempt to deal with the ground effect
      const int OFF_POINT = 10;
      const int GNDFX_POINT = 30;
      
      bottomRangeLocked = true;
      desiredBottomRange = OFF_POINT;
      
      if(bottomRange < GNDFX_POINT){
        decMotorRateLimit.delayTime = 100;
      }else{
        decMotorRateLimit.delayTime = DECRATE;
      }
      
      if(bottomRange <= desiredBottomRange){        
        hAction.cmd = HACTION_NEXT;
      }
    }
    break;
    
    case HACTION_NEXT:{ //next command
      logger("HACTION_NEXT");
      
      hAction = commands[iAction];
      char buf[SDMAXLENGTH]; logger( dumpCommand(&hAction, buf) );
      
      flipLed();
      
      iAction++;      
      if(iAction > MAXCMDS){
        hAction.cmd = HACTION_OFF;
      }
    }
    break;
    
  }
/*  
  if( checkTimer(&logSyncTimer) ){
    logger("logSync");
    sd_raw_sync();
  }
*/ 
} //loop()
void loggerInt(char *name, int value){
  char buf[SDMAXLENGTH];
  buf[0] = 0;
  strcat(buf, name);
  strcat(buf, "/");
  char buf2[16];
  itoa(value, buf2, 10);
  strcat(buf, buf2);  
  logger(buf);
}

void logger(char *s){
  char buf[SDMAXLENGTH];
  buf[0] = 0;
  ltoa(millis(), buf, 10);
  strcat(buf, ":");
  strcat(buf, s);
  Serial.println(buf);
  SDwrite(buf,true);
}

