{ skip=0 }
/^ *customSizing *: *\{\} *$/ {
  skip=1
  match($0, "^ *");
  p = substr($0, RSTART, RLENGTH);

  while((getline line<f) > 0) {
     print p line
  }  
}

{ if(!skip) { print } }
