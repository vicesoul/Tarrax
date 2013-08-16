define([
    "modernizr.custom.34982",
    'Backbone'
], function() {
    var Sketcher = window.Sketcher = Backbone.Model.extend({
        initialize: function() {
            this.brushImg = new Image();
            this.touchSupported = Modernizr.touch;
            this.writingEdge = {leftTop:{x:9999,y:9999},rightBottom:{x:0,y:0}};
            this.lastMousePoint = {x:0, y:0};
            this.brushSize = {width:10,height:10,step:.3};
            this.writeState = {};
            this.timeOut_mouseUp = {};
            this.lines = [];
            this.App = {};
            this.eraserRadius = 15;

            if (this.touchSupported) {
                this.mouseDownEvent = "touchstart";
                this.mouseMoveEvent = "touchmove";
                this.mouseUpEvent = "touchend";
            }
            else {
                this.mouseDownEvent = "mousedown";
                this.mouseMoveEvent = "mousemove";
                this.mouseUpEvent = "mouseup";
            }

            this.generalHTML();
            
            //set color and line width
            this.context.strokeStyle = "#" + this.get("color").hex;
            this.context.lineWidth = this.get("lineW");

            // bind mouseDown event
            this.canvas.on( this.mouseDownEvent, this.onCanvasMouseDown() );
            this.renderFunction = this.updateCanvasByLine;

            
        },

        defaults: {
            sketchType:"paint",
            id:"",
            lineW : 1,
            canvasW : 600,
            canvasH : 400,
            color : {hex:"000000",rgb:[0,0,0]},
            tools : {type:"line",src:""},
            appName : "sketch_app",
            appTitle : "画板"

        },

        generalHTML: function(){
          var self = this;
          var canvasHtml = '<ul class="tools">';
          canvasHtml += '<li type="button" value="清空" class="clear_all" ><i></i> </li>';
          canvasHtml += '<li type="button" value="圆珠笔" class="line" ><i></i> </li>';
          canvasHtml += '<li type="button" value="墨水" class="ink" ><i></i> </li>';
          canvasHtml += '<li type="button" value="刷子" class="big_brush" ><i></i> </li>';
          canvasHtml += '<li type="button" value="橡皮擦" class="eraser" ><i></i> </li>';
          canvasHtml += '</ul>';
          canvasHtml += '<div class="color_setting">';
          canvasHtml += '<input type="button" class="black" value="black" data-color=' + '{hex:"333333",rgb:[51,51,51]} ' + '  />';
          canvasHtml += '<input type="button" class="blue" value="blue" data-color=' + '{hex:"0000ff",rgb:[0,0,255]} ' + '  />';
          canvasHtml += '<input type="button" class="red" value="red" data-color=' + '{hex:"ff0000",rgb:[250,0,0]} ' + '  />';
          canvasHtml += '<input type="button" class="green" value="green" data-color=' + '{hex:"7cfc00",rgb:[124,252,0]} ' + '  />';
          canvasHtml += '<input type="button" class="orange" value="orange" data-color=' + '{hex:"FF7940",rgb:[255,121,64]} ' + '  />';
          canvasHtml += '<input type="button" class="yellow" value="yellow" data-color=' + '{hex:"FFFF00",rgb:[255,255,0]} ' + '  />';
          canvasHtml += '<input type="button" class="purple" value="purple" data-color=' + '{hex:"9932cc",rgb:[153,50,204]} ' + '  />';
          canvasHtml += '<input type="button" class="pink" value="pink" data-color=' + '{hex:"ff69b4",rgb:[255,105,180]} ' + '  />';
          canvasHtml += '<button class="btn btn-big">粗</button>';
          canvasHtml += '<button class="btn btn-small">细</button>';
          canvasHtml += '</div>';
          canvasHtml += '<div class="container" style="width: '+ this.get("canvasW") + 'px;height:' + this.get("canvasH") +'px;">';
          canvasHtml += '</div>';
          canvasHtml += '<div class="containerDraft"><canvas class="canvasDraft" width="39" height="39"></canvas></div>';

          this.App = $("<div></div>")
              .addClass( this.get("appName") )
              .addClass( this.get("sketchType") )
              .append(canvasHtml);

          this.canvas = $("<canvas></canvas>")
              .addClass( this.get("sketchType") )
              .attr({
                  width: this.get("canvasW"),
                  height: this.get("canvasH")
              });

          // fix windows 8 touchmove bug    
          if (typeof this.canvas[0].style.msTouchAction != 'undefined')
          this.canvas[0].style.msTouchAction = "none";

          this.context = this.canvas.get(0).getContext("2d");

          this.App.find(".container").append( this.canvas );

          this.App.find(".clear_all").click(function(){
              var response = confirm('你确定要清空画布?');
              if (response) self.clear();
            });

          this.App.find(".line").click(function(){
            self.get("tools").type = "line";
            self.App.find(".color_setting input[type=button]:first").trigger("click");
            });

          this.App.find(".ink").click(function(){
            self.set("tools", {type:"brush",src:"/javascripts/tinymce/jscripts/tiny_mce/plugins/instructure_drawing/canvas/assets/ink_s.png"});
            self.App.find(".color_setting input[type=button]:first").trigger("click");
            });

          this.App.find(".big_brush").click(function(){
            self.set("tools", {type:"brush",src:"/javascripts/tinymce/jscripts/tiny_mce/plugins/instructure_drawing/canvas/assets/brush_s.png"});
            self.App.find(".color_setting input[type=button]:first").trigger("click");
            });

          this.App.find(".eraser").click(function(){
            self.set("tools", {type : "eraser"});
            self.setTools();
            });

          this.App.find(".color_setting input[type=button]").click(function(){
            var string = $(this).attr("data-color");
            eval('self.set("color",' + string + ')');
            self.setTools();
            $(this).siblings().removeClass('active').end().addClass('active')
            });

          this.App.find(".color_setting button").click(function(){
            self.eraserRadius = $(this).is('.btn-big') ? 10 : 5
            });

          this.App.find(".tools li:not(:first)").click(function(){
            var tool = $(this).attr("class");
            self.App.find(".color_setting").attr("class","color_setting").addClass("toolSet-" + tool);
            
            self.App.find(".tools li.active").removeClass("active");
            $(this).addClass("active");
            
          })

          this.dealWithApp();

        },

        dealWithApp : function(){
            $("body").append( this.App );
            
        },

        setTools : function(){
            var self = this;
            if(self.get("tools").type == "line"){
                this.context.strokeStyle = "#" + self.get("color").hex;
                this.renderFunction = this.updateCanvasByLine;
            }else if(self.get("tools").type == "brush"){
                var canvas = $(".canvasDraft").get(0);
                var context = canvas.getContext("2d");

                context.clearRect(0,0,39,39);

                var draftBrush = new Image();
                draftBrush.src = self.get("tools").src;
                draftBrush.onload = function() {
                    context.drawImage(draftBrush,0,0,39,39);

                    var imageData = context.getImageData(0, 0, 39, 39);
                    var imgData = imageData.data;

                    for(var i = 0; i < imgData.length; i += 4) {
                        imgData[i] = self.get("color").rgb[0];
                        imgData[i + 1] = self.get("color").rgb[1];
                        imgData[i + 2] = self.get("color").rgb[2];
                    }
                    context.putImageData(imageData, 0, 0);

                    var dataURL = canvas.toDataURL();

                    var newBrush = new Image();
                    newBrush.src = dataURL;
                    newBrush.onload = function(){
                        self.brushImg = newBrush;
                        self.renderFunction = self.updateCanvasByBrush;

                    };
                };
            }else if(self.get("tools").type == "eraser"){
                self.renderFunction = self.updateCanvasByEraser;
            }
            
        },

        onCanvasMouseDown : function () {
            var self = this;
            var  nameSpace = self.defaults.sketchType
            return function(event) {

                //  right mouse is forbidden
                if( event.button == 2 )return false;        

                self.lines.push([]);

                // unbind the event if in ie, when drawing out the canvas to select the text out of canvas, than back in canvas drawing the line always drawing
                if ( $.browser.msie ){self.canvas.off( self.mouseMoveEvent + '.' + nameSpace);}

                // move event bind to document, so mouse move out and in the canvas , the lines would not mess up
                $(document).on( self.mouseMoveEvent + '.' + nameSpace, self.onCanvasMouseMove() );
                $(document).on( self.mouseUpEvent + '.' + nameSpace, self.onCanvasMouseUp() );

                self.updateMousePosition( event );
                //self.renderFunction( event );           // click drawing
                return false;      //**** ie & chrome bug, stop the mouse selecting the outer text
            }
        },

        onCanvasMouseMove : function () {
            var self = this;
            return function(event) {

                self.renderFunction( event );

                event.preventDefault();
                event.stopPropagation($(this));
                return false;
            }
        },

        onCanvasMouseUp : function (event) {
            var self = this;
            var  nameSpace = self.defaults.sketchType
            return function(event) {

                $(document).off( self.mouseMoveEvent + '.' + nameSpace );
                $(document).off( self.mouseUpEvent + '.' + nameSpace );

            }
        },

        updateMousePosition : function (event) {
            var target;
            if (this.touchSupported) {
                target = event.originalEvent.touches[0]
            }
            else {
                target = event;
            }

            var offset = this.canvas.offset();
            var writingEdge = this.writingEdge;
            this.lastMousePoint.x = target.pageX - offset.left;
            this.lastMousePoint.y = target.pageY - offset.top;

            var linesLength = this.lines.length;
            var thisPoint = [this.lastMousePoint.x,this.lastMousePoint.y];
            this.lines[linesLength-1].push(thisPoint);

            writingEdge.leftTop.x = ( target.pageX < writingEdge.leftTop.x ) ? target.pageX : writingEdge.leftTop.x ;
            writingEdge.leftTop.y = ( target.pageY < writingEdge.leftTop.y ) ? target.pageY : writingEdge.leftTop.y ;
            writingEdge.rightBottom.x = ( target.pageX > writingEdge.rightBottom.x ) ? target.pageX : writingEdge.rightBottom.x ;
            writingEdge.rightBottom.y = ( target.pageY > writingEdge.rightBottom.y ) ? target.pageY : writingEdge.rightBottom.y ;

        },

        updateCanvasByLine : function (event) {
            this.get("tools").type = "line";

            this.context.beginPath();
            this.context.moveTo( this.lastMousePoint.x, this.lastMousePoint.y );
            this.updateMousePosition( event );
            this.context.lineTo( this.lastMousePoint.x, this.lastMousePoint.y );
            this.context.stroke();
        },

        updateCanvasByBrush : function (event) {
            var self = this;
            var start = { x:this.lastMousePoint.x, y: this.lastMousePoint.y };
            this.updateMousePosition( event );
            var end = { x:this.lastMousePoint.x, y: this.lastMousePoint.y };

            var distance = parseInt( this.distanceBetween2Points( start, end ) );

            var angle = this.angleBetween2Points( start, end );

            var x,y;

            for ( var z=0; (z<distance ); z= z + self.brushSize.step )
            {
                x = start.x + (Math.sin(angle) * z) - self.brushSize.width/2;
                y = start.y + (Math.cos(angle) * z) - self.brushSize.height/2;
                self.context.drawImage(self.brushImg, x, y,self.brushSize.width,self.brushSize.height);
            }
        },

        updateCanvasByEraser : function (event) {
            var start = { x:this.lastMousePoint.x, y: this.lastMousePoint.y };
            this.updateMousePosition( event );
            var end = { x:this.lastMousePoint.x, y: this.lastMousePoint.y };

            var distance = parseInt( this.distanceBetween2Points( start, end ) );

            var angle = this.angleBetween2Points( start, end );

            var x,y;
            var r = this.eraserRadius;

            for ( var z=0; (z<distance ); z= z+this.brushSize.step )
            {
                
                x = start.x + (Math.sin(angle) * z) ;
                y = start.y + (Math.cos(angle) * z) ;
                this.context.clearRect( x-r,y-r ,2*r, 2*r );
            }
        },

        distanceBetween2Points : function ( point1, point2 ) {

            var dx = point2.x - point1.x;
            var dy = point2.y - point1.y;
            return Math.sqrt( Math.pow( dx, 2 ) + Math.pow( dy, 2 ) );
        },

        angleBetween2Points : function ( point1, point2 ) {

            var dx = point2.x - point1.x;
            var dy = point2.y - point1.y;
            return Math.atan2( dx, dy );
        },

        clear : function () {
            var c = this.canvas[0];
            c.getContext("2d").clearRect( 0, 0, c.width, c.height );
        }

    });

});
			
